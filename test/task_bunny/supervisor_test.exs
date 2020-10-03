defmodule TaskBunny.SupervisorTest do
  use ExUnit.Case, async: false
  import TaskBunny.QueueTestHelper
  alias TaskBunny.{Config, Connection, Queue, JobTestHelper}
  alias JobTestHelper.TestJob

  @host TestJob.host()
  @queue TestJob.queue_name()

  defp mock_config do
    :meck.new(Config, [:passthrough])
    :meck.expect(Config, :hosts, fn -> [@host] end)
    :meck.expect(Config, :connect_options, fn @host -> "amqp://localhost" end)
  end

  defp wait_for_process_died(pid) do
    Enum.find_value(1..100, fn _ ->
      unless Process.alive?(pid) do
        true
      else
        :timer.sleep(10)
        false
      end
    end)
  end

  defp wait_for_process_up(name) do
    Enum.find_value(1..100, fn _ ->
      if Process.whereis(name) do
        true
      else
        :timer.sleep(10)
        false
      end
    end)
  end

  setup_all do
    {:ok, _pid} =
      TaskBunny.SupervisorHelper.start_taskbunny(
        workers: [TestJob],
        publisher: {:publisher, [TestJob]}
      )

    on_exit(fn -> TaskBunny.SupervisorHelper.tear_down() end)
    :ok
  end

  setup do
    clean(Queue.queue_with_subqueues(@queue))

    mock_config()
    JobTestHelper.setup()

    JobTestHelper.wait_for_connection(@host)
    Queue.declare_with_subqueues(:default, @queue)

    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  #  FIXME have somehow broke this test
  test "starts connection and worker" do
    payload = %{"hello" => "world"}
    TestJob.enqueue(payload)
    Process.sleep(1000)

    JobTestHelper.wait_for_perform()
    assert List.first(JobTestHelper.performed_payloads()) == payload
  end

  describe "AMQP connection is lost" do
    test "recovers by restarting connection and all workers" do
      conn_name = :"TaskBunny.Connection.#{@host}"
      work_name = :"TaskBunny.Worker.#{@queue}"
      conn_pid = Process.whereis(conn_name)
      work_pid = Process.whereis(work_name)

      # Close the connection
      conn = Connection.get_connection!(@host)
      AMQP.Connection.close(conn)
      wait_for_process_died(conn_pid)
      JobTestHelper.wait_for_connection(@host)

      new_conn_pid = Process.whereis(conn_name)
      new_work_pid = Process.whereis(work_name)

      # Test if GenServer has different pids
      refute new_conn_pid == conn_pid
      refute new_work_pid == work_pid

      # Make sure worker handles the job
      payload = %{"hello" => "world"}
      TestJob.enqueue(payload, host: @host, queue: @queue)

      JobTestHelper.wait_for_perform()
      assert List.first(JobTestHelper.performed_payloads()) == payload
    end
  end

  describe "a worker crashes" do
    test "restarts the worker but connection stays" do
      conn_name = :"TaskBunny.Connection.#{@host}"
      work_name = :"TaskBunny.Worker.#{@queue}"
      conn_pid = Process.whereis(conn_name)
      work_pid = Process.whereis(work_name)

      # Kill worker
      Process.exit(work_pid, :kill)
      wait_for_process_died(work_pid)
      wait_for_process_up(work_name)

      new_conn_pid = Process.whereis(conn_name)
      new_work_pid = Process.whereis(work_name)

      # Test if the worker is restarted and connection stays same.
      assert new_conn_pid == conn_pid
      refute new_work_pid == nil
      refute new_work_pid == work_pid
    end
  end
end
