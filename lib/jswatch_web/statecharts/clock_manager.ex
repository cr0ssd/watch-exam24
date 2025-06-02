defmodule JswatchWeb.ClockManager do
  use GenServer

  require Logger

  alias JswatchWeb.Endpoint, as: UI

  @second_in_ms 1000
  @blink_interval 250
  @long_press_duration 250
  @max_blink_cycles 20

  @impl true
  def init(ui_pid) do
    :gproc.reg({:p, :l, :ui_event})
    {_, native_time} = :calendar.local_time()
    current_time = Time.from_erl!(native_time)
    default_alarm = Time.add(current_time, 10)

    Process.send_after(self(), :clock_tick, @second_in_ms)
    {:ok,
     %{
       ui_pid: ui_pid,
       current_time: current_time,
       alarm_time: default_alarm,
       state_mode: :DisplayingTime,
       active_mode: :Time,
       last_interaction_at: nil,
       is_visible: false,
       blink_counter: 0,
       editing_value: nil,
       current_selection: nil,
       is_button_held: false,
       hold_timer_ref: nil
     }}
  end

  @impl true
  def handle_info(event, state) do
    case event do
      :clock_tick -> handle_time_progression(state)
      :"bottom-right-pressed" -> handle_button_press(:right, state)
      :"bottom-left-pressed" -> handle_button_press(:left, state)
      :"bottom-right-released" -> handle_button_release(:right, state)
      :"bottom-left-released" -> handle_button_release(:left, state)
      {:check_hold, press_start, action_type} -> handle_hold_check(press_start, action_type, state)
      :editing_blink -> handle_display_blink(state)
      :exit_editing_mode -> handle_editing_exit(state)
      _ -> {:noreply, state}
    end
  end

  defp handle_time_progression(%{ui_pid: ui, current_time: time, state_mode: current_state, active_mode: active_mode, alarm_time: alarm} = state) do
    Process.send_after(self(), :clock_tick, @second_in_ms)

    updated_time = Time.add(time, 1)

    should_show_time =
      case {current_state, active_mode} do
        {:DisplayingTime, _} -> true
        {:Editing, :Alarm} -> false
        {:Editing, :Time} -> false
        _ -> false
      end

    if should_show_time do
      send_time_to_ui(ui, updated_time)
    end

    if updated_time == alarm && current_state == :DisplayingTime do
      :gproc.send({:p, :l, :ui_event}, :start_alarm)
    end

    {:noreply, %{state | current_time: updated_time}}
  end

  defp handle_button_press(button_side, %{state_mode: :DisplayingTime, is_button_held: false} = state) do
    monotonic_now = System.monotonic_time(:millisecond)
    action = if button_side == :right, do: :edit_clock, else: :edit_alarm
    Process.send_after(self(), {:check_hold, monotonic_now, action}, @long_press_duration)
    {:noreply, %{state | is_button_held: true, hold_timer_ref: monotonic_now}}
  end

  defp handle_button_press(_button_side, state) do
    {:noreply, state}
  end

  defp handle_button_release(_button_side, state) do
    {:noreply, %{state | is_button_held: false, hold_timer_ref: nil}}
  end

  defp handle_hold_check(press_start, action_type, %{is_button_held: true, hold_timer_ref: ^press_start, state_mode: :DisplayingTime, current_time: time, alarm_time: alarm, ui_pid: ui} = state) do
    stopwatch_active = case :gproc.lookup_values({:p, :l, :stopwatch_active}) do
      [] -> false
      _ -> true
    end

    if stopwatch_active do
      {:noreply, state}
    else
      if :gproc.lookup_values({:p, :l, :edit_mode}) == [] do
        :gproc.reg({:p, :l, :edit_mode})
      end

      case action_type do
        :edit_clock ->
          GenServer.cast(ui, {:set_time_display, "EDITING"})
          Process.send_after(self(), :editing_blink, @blink_interval)

          {:noreply,
           %{
             state
             | state_mode: :Editing,
               active_mode: :Time,
               current_selection: :hour,
               is_visible: true,
               blink_counter: 0,
               editing_value: time,
               last_interaction_at: nil
           }}

        :edit_alarm ->
          GenServer.cast(ui, {:set_time_display, "EDIT ALARM"})
          Process.send_after(self(), :editing_blink, @blink_interval)

          {:noreply,
           %{
             state
             | state_mode: :Editing,
               active_mode: :Alarm,
               current_selection: :hour,
               is_visible: true,
               blink_counter: 0,
               editing_value: alarm,
               last_interaction_at: nil
           }}
      end
    end
  end

  defp handle_hold_check(_press_start, _action_type, state), do: {:noreply, state}

  defp handle_display_blink(%{state_mode: :Editing, is_visible: visible, ui_pid: ui, editing_value: edit_value, current_selection: selection, blink_counter: counter} = state) do
    new_visible = !visible
    new_counter = if new_visible, do: counter + 1, else: counter

    if new_counter == @max_blink_cycles do
      send(self(), :exit_editing_mode)
      {:noreply, state}
    else
      {h, m, s} = {edit_value.hour, edit_value.minute, edit_value.second}

      display_str =
        case selection do
          :hour -> "#{if(new_visible, do: pad_zero(h), else: "  ")}:#{pad_zero(m)}:#{pad_zero(s)}"
          :minute -> "#{pad_zero(h)}:#{if(new_visible, do: pad_zero(m), else: "  ")}:#{pad_zero(s)}"
          :second -> "#{pad_zero(h)}:#{pad_zero(m)}:#{if(new_visible, do: pad_zero(s), else: "  ")}"
        end

      GenServer.cast(ui, {:set_time_display, display_str})
      Process.send_after(self(), :editing_blink, @blink_interval)

      {:noreply, %{state | is_visible: new_visible, blink_counter: new_counter}}
    end
  end

  defp handle_display_blink(state), do: {:noreply, state}

  defp handle_button_press(:right, %{state_mode: :Editing, current_selection: selection} = state) do
    next_selection =
      case selection do
        :hour -> :minute
        :minute -> :second
        :second -> :hour
      end

    {:noreply, %{state | current_selection: next_selection, blink_counter: 0}}
  end

  defp handle_button_press(:left, %{state_mode: :Editing, editing_value: edit_value, current_selection: selection, ui_pid: ui} = state) do
    adjusted_edit_time = adjust_time_segment(edit_value, selection)
    send_time_to_ui(ui, adjusted_edit_time)
    {:noreply, %{state | editing_value: adjusted_edit_time, blink_counter: 0}}
  end

  defp handle_editing_exit(%{state_mode: :Editing, editing_value: edited_value, ui_pid: ui, active_mode: mode} = state) do
    send_time_to_ui(ui, edited_value)
    :gproc.unreg({:p, :l, :edit_mode})

    final_state =
      case mode do
        :Time ->
          %{state | state_mode: :DisplayingTime, current_time: edited_value, editing_value: nil, current_selection: nil, is_visible: false, blink_counter: 0, active_mode: :Time}

        :Alarm ->
          %{state | state_mode: :DisplayingTime, alarm_time: edited_value, editing_value: nil, current_selection: nil, is_visible: false, blink_counter: 0, active_mode: :Time}
      end

    {:noreply, final_state}
  end

  defp adjust_time_segment(time, :hour), do: %{time | hour: rem(time.hour + 1, 24)}
  defp adjust_time_segment(time, :minute), do: %{time | minute: rem(time.minute + 1, 60)}
  defp adjust_time_segment(time, :second), do: %{time | second: rem(time.second + 1, 60)}

  defp pad_zero(n) when n < 10, do: "0#{n}"
  defp pad_zero(n), do: "#{n}"

  defp send_time_to_ui(ui_pid, time_val) do
    formatted_time = Time.truncate(time_val, :second) |> Time.to_string()
    GenServer.cast(ui_pid, {:set_time_display, formatted_time})
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end
end
