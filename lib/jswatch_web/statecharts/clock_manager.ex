defmodule JswatchWeb.StopwatchManager do
  use GenServer

  require Logger

  alias JswatchWeb.Endpoint, as: UI

  @initial_time ~T[00:00:00.000]
  @tick_interval 10

  @impl true
  def init(ui_pid) do
    :gproc.reg({:p, :l, :ui_event})
    display_time(ui_pid, @initial_time)
    {:ok, %{ui_pid: ui_pid, current_time: @initial_time, mode: :Time, status: :Idle, timer_ref: nil}}
  end

  @impl true
  def handle_info(event, state) do
    case event do
      :"bottom-left-pressed" -> handle_reset_or_lap(state)
      :"top-left-pressed" -> handle_mode_toggle(state)
      :"bottom-right-pressed" -> handle_start_stop_pause(state)
      :tick -> handle_counting_tick(state)
      _ ->
        {:noreply, state}
    end
  end

  defp handle_reset_or_lap(%{mode: :SWatch, status: :Working} = state) do
    new_time = @initial_time
    display_time(state.ui_pid, new_time)
    {:noreply, %{state | current_time: new_time}}
  end

  defp handle_reset_or_lap(state) do
    {:noreply, state}
  end

  defp handle_mode_toggle(%{ui_pid: ui, mode: current_mode, current_time: time} = state) do
    new_mode =
      if current_mode == :SWatch do
        :Time
      else
        display_time(ui, time)
        :SWatch
      end
    {:noreply, %{state | mode: new_mode}}
  end

  defp handle_start_stop_pause(%{mode: :SWatch, status: :Idle, current_time: time} = state) do
    case :gproc.lookup_values({:p, :l, :edit_mode}) do
      [] ->
        updated_time = Time.add(time, @tick_interval, :millisecond)
        timer = Process.send_after(self(), :tick, @tick_interval)
        display_time(state.ui_pid, updated_time)
        :gproc.reg({:p, :l, :stopwatch_active})
        {:noreply, %{state | status: :Running, current_time: updated_time, timer_ref: timer}}
      _ ->
        {:noreply, state}
    end
  end

  defp handle_start_stop_pause(%{mode: :SWatch, status: :Running, timer_ref: timer} = state) do
    if timer != nil, do: Process.cancel_timer(timer)
    :gproc.unreg({:p, :l, :stopwatch_active})
    {:noreply, %{state | status: :Idle, timer_ref: nil}}
  end

  defp handle_start_stop_pause(state) do
    {:noreply, state}
  end

  defp handle_counting_tick(%{ui_pid: ui, status: :Running, mode: mode, current_time: time} = state) do
    updated_time = Time.add(time, @tick_interval, :millisecond)
    new_timer = Process.send_after(self(), :tick, @tick_interval)

    if mode == :SWatch do
      display_time(ui, updated_time)
    end

    {:noreply, %{state | current_time: updated_time, timer_ref: new_timer}}
  end

  defp display_time(ui_pid, time_val) do
    formatted_time = time_val |> Time.to_string() |> String.slice(3, 8)
    GenServer.cast(ui_pid, {:set_time_display, formatted_time})
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end
end
