defmodule Phoenix.PubSub.RedisZ.RedisSubscriber do
  @moduledoc false

  alias Phoenix.PubSub.RedisZ.Local

  require Logger

  use GenServer

  @reconnect_after_ms 5_000
  @redix_options [:host, :port, :password, :database]

  def server_name(pubsub_server, shard) do
    Module.concat(["#{pubsub_server}.RedisZ.Subscriber#{shard}"])
  end

  def start_link(server_name, options) do
    Logger.info("Starts pubsub subscriber: #{server_name}")
    GenServer.start_link(__MODULE__, options, name: server_name)
  end

  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      pubsub_server: options[:pubsub_server],
      node_ref: options[:node_ref],
      redix_pid: nil,
      reconnect_timer: nil,
      redis_options: options[:redis_options]
    }

    {:ok, establish_conn(state)}
  end

  def handle_call({:subscribe, _pid, topic}, _from, state) do
    :ok = Redix.PubSub.subscribe(state.redix_pid, topic, self())
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, _pid, topic}, _from, state) do
    :ok = Redix.PubSub.unsubscribe(state.redix_pid, topic, self())
    {:reply, :ok, state}
  end

  def handle_info(:establish_conn, state) do
    {:noreply, establish_conn(%{state | reconnect_timer: nil})}
  end

  def handle_info({:redix_pubsub, redix_pid, :subscribed, _}, %{redix_pid: redix_pid} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:redix_pubsub, redix_pid, :disconnected, %{reason: reason}},
        %{redix_pid: redix_pid} = state
      ) do
    Logger.error(
      "Phoenix.PubSub disconnected from Redis with reason #{inspect(reason)} (awaiting reconnection)"
    )

    {:noreply, state}
  end

  def handle_info(
        {:redix_pubsub, redix_pid, :message, %{payload: bin_msg}},
        %{redix_pid: redix_pid} = state
      ) do
    {remote_node_ref, fastlane, pool_size, from, topic, msg} = :erlang.binary_to_term(bin_msg)

    if remote_node_ref == state.node_ref do
      Local.broadcast(fastlane, state.pubsub_server, pool_size, from, topic, msg)
    else
      Local.broadcast(fastlane, state.pubsub_server, pool_size, :none, topic, msg)
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, redix_pid, _reason}, %{redix_pid: redix_pid} = state) do
    {:noreply, establish_conn(state)}
  end

  def handle_info({:EXIT, _, _reason}, state), do: {:noreply, state}

  def terminate(_reason, _state), do: :ok

  defp schedule_reconnect(state) do
    if state.reconnect_timer, do: :timer.cancel(state.reconnect_timer)
    {:ok, timer} = :timer.send_after(@reconnect_after_ms, :establish_conn)
    timer
  end

  defp establish_conn(state) do
    redis_options = Keyword.take(state.redis_options, @redix_options)

    case Redix.PubSub.start_link(redis_options, sync_connect: true) do
      {:ok, redix_pid} -> %{state | redix_pid: redix_pid}
      {:error, _} -> establish_failed(state)
    end
  end

  defp establish_failed(state) do
    Logger.error("Unable to establish initial redis connection. Attempting to reconnect...")
    %{state | redix_pid: nil, reconnect_timer: schedule_reconnect(state)}
  end
end
