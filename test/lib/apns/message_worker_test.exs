defmodule APNS.MessageWorkerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias APNS.MessageWorker
  alias APNS.FakeSender
  alias APNS.FakeRetrier

  @moduletag :capture_log

  setup do
    config = %{
      apple_port: 2195,
      timeout: 10,
      apple_host: "host.apple",
      callback_module: APNS.Callback,
      payload_limit: 256,
      reconnect_after: 3
    }
    state = %{
      config: config,
      socket_apple: %{},
      ssl_opts: [],
      counter: 0,
      queue: [],
      pool: :test
    }
    token = "1becf2320bcd26819f96d2d75d58b5e81b11243286bc8e21f54c374aa44a9155"
    message =
      APNS.Message.new(23)
      |> Map.put(:token, token)
      |> Map.put(:alert, "Lorem ipsum dolor sit amet, consectetur adipisicing elit")

    {:ok, state: state, token: token, message: message}
  end

  @tag :real
  test "handle_call :send calls GenServer", %{token: token} do
    worker = :poolboy.checkout(:"APNS.Pool.test")
    message =
      APNS.Message.new(23)
      |> Map.put(:token, token)
      |> Map.put(:alert, "Lorem ipsum dolor sit amet, consectetur adipisicing elit")

    output = capture_log(fn -> assert :ok = MessageWorker.send(worker, message) end)
    assert output =~ ~s([APNS] success sending 23 to #{token})
  end

  test "init calls connect with state" do
    config = [
      apple_port: 2196,
      timeout: 9,
      apple_host: "feedback.apple",
      callback_module: APNS.Callback,
      pool: :test
    ]
    assert {:connect, :init, %{config: %APNS.Configuration{}, buffer_apple: ""}} = MessageWorker.init(config)
  end

  test "connect calls close before connecting", %{state: state} do
    output = capture_log(fn -> MessageWorker.connect(:anything, state, FakeSender) end)
    assert output =~ ~s(APNS.FakeSender.connect_socket)
  end

  test "connect connects to configured host", %{state: state} do
    output = capture_log(fn -> MessageWorker.connect(:anything, state, FakeSender) end)
    assert output =~ ~s(APNS.FakeSender.connect_socket/4)
    assert output =~ ~s(host: 'host.apple')
    assert output =~ ~s(port: 2195)
    assert output =~ ~s(opts: [])
    assert output =~ ~s(timeout: 10)
  end

  test "connect returns ok if connection succeeded", %{state: state} do
    assert {:ok, %{config: %{apple_host: "host.apple"}}} = MessageWorker.connect(:anything, state, FakeSender)
  end

  test "connect returns error if connection failed", %{state: state} do
    result = MessageWorker.connect(:anything, state, APNS.FakeSenderConnectFail)
    assert result == {:backoff, 1000, state}
  end

  test "handle_call :send calls error callback if token is invalid size", %{state: state, message: message} do
    token = String.duplicate("0", 63)
    message = Map.put(message, :token, token)
    output = capture_log(fn ->
      assert MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier) == {:reply, :ok, state}
    end)
    assert output =~ ~s([APNS] Error "Invalid token size" for message 23 to #{token})
  end

  test "handle_call :send calls error callback if payload is too big", %{state: state, message: message} do
    state = put_in(state, [:config, :payload_limit], 10)
    output = capture_log(fn ->
      assert MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier) == {:reply, :ok, state}
    end)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 23)
  end

  @tag :pending # shouldn't this pass? See APNS.Payload.to_json
  test "handle_call :send calls error callback if payload size can be set per message", %{state: state, message: message} do
    message = Map.put(message, :support_old_ios, true)
    message = Map.put(message, :alert, String.duplicate("0", 2000))
    output = capture_log(fn -> MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier) end)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 23)
  end

  test "handle_call :send sends payload to Apple", %{state: state, message: message, token: token} do
    output = capture_log(fn ->
      result = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
      assert {:reply, :ok, %{queue: [^message], counter: 1}} = result
    end)
    assert output =~ ~s(APNS.FakeSender.send_package/2)
    assert output =~ ~s(to #{token})
  end

  test "handle_call :send puts the failed message back on the queue for re-sending", %{state: state, message: message} do
    output = capture_log(fn ->
      result = MessageWorker.handle_call({:send, message}, :from, state, APNS.FakeSenderSendPackageFail, FakeRetrier)
      assert result == {:disconnect, {:error, "FakeSenderSendPackageFail failed"}, {:error, "FakeSenderSendPackageFail failed"}, state}
    end)
    assert output =~ ~s/[APNS] reconnecting worker #{inspect(self())} due to conection error "FakeSenderSendPackageFail failed"/
    assert output =~ ~s/[APNS] error (FakeSenderSendPackageFail failed) sending 23 to #{message.token} retrying…/
    assert output =~ ~s(APNS.FakeRetrier.send/2 pool: :test)
    assert output =~ ~s(id: 23)
  end

  test "handle_call :send don't put messages that have failed more than 10 times back for re-sending", %{state: state, message: message} do
    message = Map.put(message, :retry_count, 10)
    output = capture_log(fn ->
      result = MessageWorker.handle_call({:send, message}, :from, state, APNS.FakeSenderSendPackageFail, FakeRetrier)
      assert result == {:disconnect, {:error, "FakeSenderSendPackageFail failed"}, {:error, "FakeSenderSendPackageFail failed"}, state}
    end)
    assert output =~ ~s/[APNS] 10th error (FakeSenderSendPackageFail failed) sending 23 to #{message.token} message will not be delivered/
    refute output =~ ~s(APNS.FakeRetrier.send/2 pool: :test)
  end

  test "handle_call :send reconnects after configured amount of pushes", %{state: state, message: message} do
    {:reply, :ok, state} = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
    {:reply, :ok, state} = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
    {:reply, :ok, state} = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
    output = capture_log(fn -> MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier) end)
    assert output =~ ~s([APNS] 3 messages sent, reconnecting)
    assert output =~ ~s(APNS.FakeSender.connect_socket)
  end

  test "handle_call :send counts number of pushes", %{state: state, message: message} do
    {:reply, :ok, state} = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
    {:reply, :ok, state} = MessageWorker.handle_call({:send, message}, :from, state, FakeSender, FakeRetrier)
    assert state.counter == 2
  end

  test "handle_info :ssl calls error callback if status byte is 0" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(0)) end)
    assert output =~ ~s([APNS] Error "No errors encountered" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 1" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(1)) end)
    assert output =~ ~s([APNS] Error "Processing error" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 2" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(2)) end)
    assert output =~ ~s([APNS] Error "Missing device token" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 3" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(3)) end)
    assert output =~ ~s([APNS] Error "Missing topic" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 4" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(4)) end)
    assert output =~ ~s([APNS] Error "Missing payload" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 5" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(5)) end)
    assert output =~ ~s([APNS] Error "Invalid token size" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 6" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(6)) end)
    assert output =~ ~s([APNS] Error "Invalid topic size" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 7" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(7)) end)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 8" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(8)) end)
    assert output =~ ~s([APNS] Error "Invalid token" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 10" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(10)) end)
    assert output =~ ~s([APNS] Error "Shutdown" for message 1234)
  end

  test "handle_info :ssl calls error callback if status byte is 255" do
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(255)) end)
    assert output =~ ~s/[APNS] Error "None (unknown)" for message 1234/
  end

  test "handle_info :ssl retries messages later in queue" do
    message1 = APNS.Message.new(1)
    message2 = APNS.Message.new(1234)
    message3 = APNS.Message.new(3)
    message4 = APNS.Message.new(4)
    queue = [message4, message3, message2, message1]

    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", ""}, response_state(8, queue), FakeRetrier) end)
    assert output =~ ~s(APNS.FakeRetrier.send/2 pool: :test)
    assert output =~ ~s(id: 4)
    assert output =~ ~s(id: 3)
    refute output =~ ~s(id: 1234)
    refute output =~ ~s(id: 1)
  end

  test "handle_info :ssl clears queue on error" do
    message1 = APNS.Message.new(1)
    message2 = APNS.Message.new(1234)
    message3 = APNS.Message.new(3)
    queue = [message3, message2, message1]

    assert {:noreply, %{queue: []}} = MessageWorker.handle_info({:ssl, "socket", ""}, response_state(8, queue), FakeRetrier)
  end

  test "handle_info :ssl returns state if rest is blank" do
    input_state = response_state(8)
    {:noreply, state} = MessageWorker.handle_info({:ssl, "socket", ""}, input_state)

    assert state == input_state
  end

  test "handle_info :ssl iterates over packages until rest is blank" do
    state = response_state(6)
    package1 = apple_buffer(8)
    package2 = apple_buffer(7)
    data = <<package1 :: binary, package2 :: binary>>
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", data}, state) end)

    assert output =~ ~s([APNS] Error "Invalid topic size" for message 1234)
    assert output =~ ~s([APNS] Error "Invalid token" for message 1234)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 1234)
  end

  @tag :pending # should we support this case?
  test "handle_info :ssl iteration works with error response after success", %{apple_success_buffer: apple_success_buffer} do
    state = %{buffer_apple: apple_success_buffer, config: %{callback_module: APNS.Callback}, queue: []}
    package1 = apple_buffer(8)
    package2 = apple_buffer(7)
    data = <<package1 :: binary, package2 :: binary>>
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", data}, state) end)

    assert output =~ ~s([APNS] Error "Invalid token" for message 1234)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 1234)
  end

  @tag :pending # should we support this case?
  test "handle_info :ssl iteration works with success response after error", %{apple_success_buffer: apple_success_buffer} do
    state = response_state(6)
    package1 = apple_buffer(8)
    package2 = apple_success_buffer
    package3 = apple_buffer(7)
    data = <<package1 :: binary, package2 :: binary, package3 :: binary>>
    output = capture_log(fn -> MessageWorker.handle_info({:ssl, "socket", data}, state) end)

    assert output =~ ~s([APNS] Error "Invalid topic size" for message 1234)
    assert output =~ ~s([APNS] Error "Invalid token" for message 1234)
    assert output =~ ~s([APNS] Error "Invalid payload size" for message 1234)
  end

  defp response_state(status_code, queue \\ []) do
    %{
      buffer_apple: apple_buffer(status_code),
      socket_apple: "socket",
      config: %{callback_module: APNS.Callback},
      queue: queue,
      pool: :test
    }
  end

  defp apple_buffer(status_code) do
    <<8 :: 8, status_code :: 8, 1234 :: integer-32>>
  end
end
