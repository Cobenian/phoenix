defmodule Phoenix.ChannelTest do
  use ExUnit.Case, async: true

  alias Phoenix.PubSub
  alias Phoenix.Channel
  alias Phoenix.Socket
  alias Phoenix.Socket.Message
  alias Phoenix.Channel.Transport
  alias Phoenix.Transports.WebSocket
  alias Phoenix.Transports.LongPoller

  defmodule Endpoint do
    def __pubsub_server__(), do: :phx_pub
  end

  defmodule BlankChannel do
    use Phoenix.Channel
    def join(_topic, _msg, socket), do: {:ok, socket}

    def handle_in(_event, _msg, socket) do
      {:ok, socket}
    end
  end

  defmodule MyChannel do
    use Phoenix.Channel
    def join(topic, msg, socket) do
      send socket.transport_pid, {:join, topic}
      msg.(socket)
    end
    def leave(_msg, socket) do
      send socket.transport_pid, :leave_triggered
      if on_leave = Process.get(:leave) do
        on_leave.(socket)
      else
        {:ok, socket}
      end
    end

    def handle_info({:ping, sender}, socket) do
      send sender, :pong
      {:ok, socket}
    end
    def handle_info({:close, sender}, socket) do
      send sender, :closing
      {:leave, socket}
    end

    def handle_in("some:event", _msg, socket) do
      send socket.transport_pid, {:handle_in, socket.topic}
      {:ok, socket}
    end
    def handle_in("boom", msg, socket), do: msg.(socket)
    def handle_in("put", dict, socket) do
      {:ok, Enum.reduce(dict, socket, fn {k, v}, sock -> Socket.assign(sock, k, v) end)}
    end
    def handle_in("get", %{"key" => key}, socket) do
      send socket.transport_pid, socket.assigns[key]
      {:ok, socket}
    end
    def handle_in("should:be:going", _msg, socket) do
      {:leave, socket}
    end

    def handle_out("some:broadcast", _msg, socket) do
      send socket.transport_pid, :handle_out
      {:ok, socket}
    end
    def handle_out("everyone:leave", _msg, socket) do
      send socket.transport_pid, :everyone_leaving
      {:leave, socket}
    end
    def handle_out(event, message, socket) do
      push socket, event, message
    end
  end

  defmodule Router do
    use Phoenix.Router

    socket "/ws" do
      channel "topic:*", MyChannel
      channel "baretopic", MyChannel
      channel "wsonly:*", MyChannel, via: [WebSocket]
      channel "lponly:*", MyChannel, via: [LongPoller]
    end

    socket "/ws2", Phoenix.ChannelTest, via: [WebSocket] do
      channel "topic2:*", Elixir.MyChannel
      channel "topic2-override:*", Elixir.MyChannel, via: [LongPoller]
    end

    socket "/ws3", alias: Phoenix.ChannelTest do
      channel "topic3:*", Elixir.MyChannel
    end
  end

  def new_socket do
    %Socket{transport_pid: self,
            router: Router,
            topic: "topic1:subtopic",
            assigns: []}
  end

  def join_message(topic, func) do
    %Message{topic: topic,
             event: "join",
             payload: func}
  end

  def subscribers(server, topic) do
    PubSub.Local.subscribers(Module.concat(server, Local), topic)
  end

  setup do
    Process.flag(:trap_exit, true)
    Logger.disable(self())
    :ok
  end

  test "#subscribe/unsubscribe's socket to/from topic" do
    socket = Socket.put_topic(new_socket, "top:subtop")

    assert PubSub.subscribe(:phx_pub, socket.transport_pid, "top:subtop")
    assert subscribers(:phx_pub, "top:subtop") == [socket.transport_pid]
    assert PubSub.unsubscribe(:phx_pub, socket.transport_pid, "top:subtop")
    assert subscribers(:phx_pub, "top:subtop") == []
  end

  test "#broadcast and #broadcast! broadcasts global message on topic" do
    socket = Socket.put_topic(new_socket, "top:subtop")

    assert Channel.broadcast(:phx_pub, socket, "event", %{foo: "bar"})
    assert Channel.broadcast!(:phx_pub, socket, "event", %{foo: "bar"})
  end


  test "#broadcast and #broadcast! raises friendly error when message arg isn't a Map" do
    message = "Message argument must be a map"
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast(:phx_pub, "topic:subtopic", "event", bar: "foo", foo: "bar")
    end
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast!(:phx_pub, "topic:subtopic", "event", bar: "foo", foo: "bar")
    end
  end

  test "#broadcast_from and #broadcast_from! broadcasts message, skipping publisher" do
    socket = new_socket |> Socket.put_topic("top:subtop")
    PubSub.subscribe(:phx_pub, socket.transport_pid, "top:subtop")

    assert Channel.broadcast_from(:phx_pub, socket, "event", %{payload: "hello"})
    refute Enum.any?(Process.info(self)[:messages], &match?(%Message{}, &1))

    assert Channel.broadcast_from!(:phx_pub, socket, "event", %{payload: "hello"})
    refute Enum.any?(Process.info(self)[:messages], &match?(%Message{}, &1))
  end

  test "#broadcast_from and #broadcast_from! raises error when msg isn't a Map" do
    socket = Socket.put_topic(new_socket, "top:subtop")
    message = "Message argument must be a map"
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast_from(:phx_pub, socket, "event", bar: "foo", foo: "bar")
    end
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast_from!(:phx_pub, socket, "event", bar: "foo", foo: "bar")
    end
  end

  test "#broadcast_from/4 and broadcast_from!/4 raises error when msg isn't a Map" do
    message = "Message argument must be a map"
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast_from(:phx_pub, self, "topic:subtopic", "event", bar: "foo")
    end
    assert_raise RuntimeError, message, fn ->
      Channel.broadcast_from!(:phx_pub, self, "topic:subtopic", "event", bar: "foo")
    end
  end

  test "#push sends response to socket" do
    socket = Socket.put_topic(new_socket, "top:subtop")
    assert Channel.push(socket, "event", %{payload: "hello"})

    assert Enum.any?(Process.info(self)[:messages], &match?({:socket_push, %Message{}}, &1))
    assert_received {:socket_push, %Message{
      topic: "top:subtop",
      event: "event",
      payload: %{payload: "hello"}
    }}
  end

  test "#push raises friendly error when message arg isn't a Map" do
    socket = Socket.put_topic(new_socket, "top:subtop")
    message = "Message argument must be a map"
    assert_raise RuntimeError, message, fn ->
      Channel.push(socket, "event", foo: "bar", bar: "foo")
    end
  end

  test "Default #leave is generated as a noop" do
    assert {:ok, %Socket{}} = BlankChannel.leave(%{}, new_socket)
  end

  test "#leave can be overridden" do
    Process.put(:leave, fn _ -> :overridden end)
    assert MyChannel.leave(%{}, new_socket) == :overridden
  end

  test "handle_in and handle_out callbacks can return {:leave, socket} to leave channel" do
    # join
    join = fn ->
      message = join_message("topic:1subtopic", fn socket -> {:ok, socket} end)
      assert subscribers(:phx_pub, "topic:1subtopic") == []
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    end
    sockets = HashDict.new

    # incoming leave
    {:ok, socket_pid} = join.()
    sockets = HashDict.put(sockets, "topic:1subtopic", socket_pid)
    assert subscribers(:phx_pub, "topic:1subtopic") == [socket_pid]
    # send message that returns {:leave, socket} now that we've joined
    message = %Message{topic: "topic:1subtopic",
                       event: "should:be:going",
                       payload: %{}}
    :ok = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    Process.monitor(socket_pid)
    assert_receive :leave_triggered
    assert_receive {:DOWN, _ref, :process, ^socket_pid, :normal}
    assert subscribers(:phx_pub, "topic:1subtopic") == []

    # outgoing leave
    {:ok, sock_pid} = join.()
    sockets = HashDict.put(sockets, "topic:1subtopic", sock_pid)
    assert subscribers(:phx_pub, "topic:1subtopic") == [sock_pid]
    # send broadcast that returns {:leave, socket} now that we've joined
    msg = %Message{event: "everyone:leave", topic: "topic:1subtopic", payload: %{}}
    Enum.each sockets, fn {_, pid} -> Process.monitor(pid) end
    PubSub.broadcast!(:phx_pub, msg.topic, {:socket_broadcast, msg})
    Enum.each sockets, fn {_, pid} ->
      assert_receive {:DOWN, _ref, :process, ^pid, :normal}
    end

    assert subscribers(:phx_pub, "topic:1subtopic") == []
    assert_received :everyone_leaving
    assert_received :leave_triggered
  end

  test "successful join authorizes and subscribes socket to topic" do
    message = join_message("topic:2subtopic", fn socket -> {:ok, socket} end)
    sockets = HashDict.new

    assert subscribers(:phx_pub, "topic:2subtopic") == []
    {:ok, socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert subscribers(:phx_pub, "topic:2subtopic") == [socket_pid]
  end

  test "unsuccessful join denies socket access to topic" do
    message = join_message("topic:3subtopic", fn _socket -> :ignore end)

    assert subscribers(:phx_pub, "topic:3subtopic") == []
    :ignore = Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    refute subscribers(:phx_pub, "topic:3subtopic") == [self]
  end

  test "#leave is called when the socket conn closes, and is unsubscribed" do
    message = join_message("topic:4subtopic", fn socket -> {:ok, socket} end)

    {:ok, socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    Process.monitor(socket_pid)
    assert subscribers(:phx_pub, "topic:4subtopic") == [socket_pid]
    Process.put(:leave, fn socket -> {:ok, socket} end)
    Process.exit(socket_pid, :shutdown)

    assert_receive {:EXIT, ^socket_pid, :shutdown}
    assert subscribers(:phx_pub, "topic:4subtopic") == []
  end

  test "#join raise InvalidReturnError exception when return type invalid" do
    message = join_message("topic:5subtopic", fn _socket -> :badreturn end)

    assert {:error, {:badarg, :badreturn}} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
  end

  test "#leave raise InvalidReturnError exception when return type invalid" do
    message = join_message("topic:6subtopic", fn socket -> {:ok, socket} end)

    {:ok, socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    Process.put(:leave, fn _ -> :badreturn end)
    Process.monitor(socket_pid)
    Process.exit(socket_pid, :shutdown)

    assert_receive {:EXIT, ^socket_pid, :shutdown}
  end

  test "#event raises InvalidReturnError exception when return type is invalid" do
    message = join_message("topic:7subtopic", fn socket -> {:ok, socket} end)

    {:ok, socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    sockets = HashDict.put(HashDict.new, "topic:7subtopic", socket_pid)
    message = %Message{topic: "topic:7subtopic",
                       event: "boom",
                       payload: fn _socket -> :badreturn end}

    Process.unlink(socket_pid)
    Process.monitor(socket_pid)
    Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_receive {:DOWN, _, :process, ^socket_pid, _}
  end

  test "returns heartbeat message when received, and does not store socket" do
    msg = %Message{topic: "phoenix", event: "heartbeat", payload: fn _socket -> :badreturn end}

    Transport.dispatch(msg, HashDict.new, self, Router, Endpoint, WebSocket)
    assert_received {:socket_push, %Message{topic: "phoenix", event: "heartbeat"}}
  end

  test "Socket state can be put and retrieved" do
    {:ok, socket} = MyChannel.handle_in("put", %{val: 123}, new_socket)
    {:ok, _socket} = MyChannel.handle_in("get", %{"key" => :val}, socket)
    assert_received 123
  end

  test "handle_out/3 can be overidden for custom broadcast handling" do
    message = join_message("topic:8subtopic", fn socket -> {:ok, socket} end)
    sockets = HashDict.new

    {:ok, _socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)

    PubSub.broadcast!(:phx_pub, "topic:8subtopic", {:socket_broadcast, %Message{event: "some:broadcast",
                                         topic: "topic:8subtopic",
                                         payload: "hello"}})
    assert_receive :handle_out
  end

  test "join/3 and handle_in/3 match splat topics" do
    message = %Message{topic: "topic:9somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    sockets = HashDict.new

    {:ok, socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_received {:join, "topic:9somesubtopic"}
    sockets = HashDict.put(sockets, "topic:9somesubtopic", socket_pid)

    message = %Message{topic: "topic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    :ignore = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    refute_received {:join, "topic"}

    message = %Message{topic: "topic:9somesubtopic",
                       event: "some:event",
                       payload: fn socket -> {:ok, socket} end}
    :ok = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_receive {:handle_in, "topic:9somesubtopic"}

    message = %Message{topic: "topic:somesub",
                       event: "some:event",
                       payload: fn socket -> {:ok, socket} end}
    :ignore = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    refute_received {:handle_in, "topic:somesub"}
  end

  test "join/3 and handle_in/3 match bare topics" do
    message = %Message{topic: "baretopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    sockets = HashDict.new

    {:ok, socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_received {:join, "baretopic"}
    sockets = HashDict.put(sockets, "baretopic", socket_pid)

    message = %Message{topic: "baretopic:sub",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    :ignore = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    refute_received {:join, "baretopic:sub"}

    message = %Message{topic: "baretopic",
                       event: "some:event",
                       payload: fn socket -> {:ok, socket} end}
    :ok = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_receive {:handle_in, "baretopic"}

    message = %Message{topic: "baretopic:sub",
                       event: "some:event",
                       payload: fn socket -> {:ok, socket} end}
    :ignore = Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    refute_receive {:handle_in, "baretopic:sub"}
  end

  test "channel `via:` option filters messages by transport" do
    # via WS
    message = %Message{topic: "wsonly:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    sockets = HashDict.new
    {:ok, _socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, WebSocket)
    assert_received {:join, "wsonly:somesubtopic"}

    :ignore = Transport.dispatch(message, HashDict.new, self, Router, Endpoint, LongPoller)
    refute_received {:join, "wsonly:somesubtopic"}

    # via LP
    message = %Message{topic: "lponly:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    sockets = HashDict.new
    {:ok, _socket_pid} =
      Transport.dispatch(message, sockets, self, Router, Endpoint, LongPoller)
    assert_received {:join, "lponly:somesubtopic"}

    :ignore = Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    refute_received {:join, "lponly:somesubtopic"}
  end

  test "unmatched channel message ignores message" do
    msg = %Message{topic: "ensurebadmatch:somesubtopic",
                   event: "join",
                   payload: fn socket -> {:ok, socket} end}
    assert nil == Router.channel_for_topic(msg.topic, WebSocket)
    :ignore = Transport.dispatch(msg, HashDict.new, self, Router, Endpoint, WebSocket)
    refute_received {:join, "ensurebadmatch:somesubtopic"}
  end

  test "socket/3 with alias option" do
    message = %Message{topic: "topic2:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    {:ok, _socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    assert_received {:join, "topic2:somesubtopic"}
  end

  test "socket/3 with alias applies :alias option" do
    message = %Message{topic: "topic3:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    {:ok, _socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    assert_received {:join, "topic3:somesubtopic"}
  end

  test "socket/3 with via applies overridable transport filters to all channels" do
    message = %Message{topic: "topic2:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    :ignore = Transport.dispatch(message, HashDict.new, self, Router, Endpoint, LongPoller)
    refute_received {:join, "topic2:somesubtopic"}

    message = %Message{topic: "topic2-override:somesubtopic",
                       event: "join",
                       payload: fn socket -> {:ok, socket} end}
    {:ok, _socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, LongPoller)
    assert_received {:join, "topic2-override:somesubtopic"}

    Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    refute_received {:join, "topic2-override:somesubtopic"}
  end

  test "handle_info/2 is triggered for any elixir message" do
    message = join_message("topic:10subtopic", fn socket -> {:ok, socket} end)
    {:ok, socket_pid} =
      Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)

    send(socket_pid, {:ping, self})
    assert_receive :pong
  end

  test "handle_info/2 can close socket by returning {:leave, socket}" do
    message = join_message("topic:10subtopic", fn socket -> {:ok, socket} end)
    {:ok, socket_pid} = Transport.dispatch(message, HashDict.new, self, Router, Endpoint, WebSocket)
    Process.monitor(socket_pid)

    send(socket_pid, {:close, self})
    assert_receive :closing
    assert_receive {:DOWN, _ref, :process, ^socket_pid, :normal}
  end

end
