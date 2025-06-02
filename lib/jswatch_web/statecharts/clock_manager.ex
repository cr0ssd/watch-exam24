defmodule JswatchWeb.ClockManager do
  use GenServer

  require Logger

  alias JswatchWeb.Endpoint, as: UI

  @update_interval 1000
  @long_press_threshold 250
  @blink_cycle_duration 250
  @max_blink_repetitions 20

  @impl true
  def init(display_pid) do
    :gproc.reg({:p, :l, :ui_event})
    {_, current_erl_time} = :calendar.local_time()
    current_time_val = Time.from_erl!(current_erl_time)
    default_alarm_val = Time.add(current_time_val, 10)

    Process.send_after(self(), :clock_pulse, @update_interval)
    {:ok, %{
      ui_pid: display_pid,
      main_time: current_time_val,
      alarm_setting: default_alarm_val,
      activity_mode: :Viewing,
      display_mode: :Clock,
      last_event_time: nil,
      is_display_on: false,
      blink_iteration: 0,
      temp_edit_time: nil,
      active_segment: nil,
      is_key_down: false,
      key_press_timer: nil
    }}
  end

  @impl true
  def handle_info(message, state) do
    case message do
      :clock_pulse -> process_clock_tick(state)
      :"bottom-right-pressed" -> handle_button_input(:right_down, state)
      :"bottom-left-pressed" -> handle_button_input(:left_down, state)
      :"bottom-right-released" -> handle_button_input(:right_up, state)
      :"bottom-left-released" -> handle_button_input(:left_up, state)
      {:check_hold_duration, press_start, edit_kind} -> verify_button_hold(press_start, edit_kind, state)
      :blink_animation -> update_editing_display(state)
      :finalize_edit -> exit_editing_state(state)
      :clock_pulse when state.activity_mode == :Editing -> {:noreply, state}
      :"bottom-right-pressed" when state.activity_mode == :Editing -> {:noreply, state}
      :"bottom-left-pressed" when state.activity_mode == :Editing -> {:noreply, state}
      {:check_hold_duration, _press_start, _edit_type} when state.activity_mode == :Editing -> {:noreply, state}
      :"top-right-pressed" -> {:noreply, state}
      :"top-right-released" -> {:noreply, state}
      :"top-left-pressed" -> {:noreply, state}
      :"top-left-released" -> {:noreply, state}
      :"bottom-right-pressed" -> {:noreply, state}
      {:check_hold_duration, _press_start, _edit_type} when state.activity_mode not in [:Editing] -> {:noreply, state}
      :start_alarm -> {:noreply, state}
      _ -> raise "Unexpected message in manager: #{inspect(message)}"
    end
  end

  defp process_clock_tick(%{ui_pid: display_pid, main_time: time, activity_mode: current_activity, display_mode: current_display, alarm_setting: alarm_val} = state) do
    Process.send_after(self(), :clock_pulse, @update_interval)

    new_time = Time.add(time, 1)

    should_update_display =
      case {current_activity, current_display} do
        {:Viewing, _} -> true
        {:Editing, :Alarm} -> false
        {:Editing, :Clock} -> false
        _ -> false
      end

    if should_update_display do
      update_ui_time(display_pid, new_time)
    end

    if new_time == alarm_val and current_activity == :Viewing do
      :gproc.send({:p, :l, :ui_event}, :start_alarm)
    end

    {:noreply, %{state | main_time: new_time}}
  end

  defp handle_button_input(:right_down, %{activity_mode: :Viewing, is_key_down: false} = state) do
    current_mono_time = System.monotonic_time(:millisecond)
    Process.send_after(self(), {:check_hold_duration, current_mono_time, :time_adjust}, @long_press_threshold)
    {:noreply, %{state | is_key_down: true, key_press_timer: current_mono_time}}
  end

  defp handle_button_input(:left_down, %{activity_mode: :Viewing, is_key_down: false} = state) do
    current_mono_time = System.monotonic_time(:millisecond)
    Process.send_after(self(), {:check_hold_duration, current_mono_time, :alarm_adjust}, @long_press_threshold)
    {:noreply, %{state | is_key_down: true, key_press_timer: current_mono_time}}
  end

  defp handle_button_input(:right_up, state), do: {:noreply, %{state | is_key_down: false, key_press_timer: nil}}
  defp handle_button_input(:left_up, state), do: {:noreply, %{state | is_key_down: false, key_press_timer: nil}}

  defp handle_button_input(:right_down, %{activity_mode: :Editing, active_segment: current_segment} = state) do
    next_segment =
      case current_segment do
        :hour -> :minute
        :minute -> :second
        :second -> :hour
      end
    {:noreply, %{state | active_segment: next_segment, blink_iteration: 0}}
  end

  defp handle_button_input(:left_down, %{activity_mode: :Editing, temp_edit_time: edit_time, active_segment: segment, ui_pid: display_pid} = state) do
    adjusted_time = increment_time_part(edit_time, segment)
    update_ui_time(display_pid, adjusted_time)
    {:noreply, %{state | temp_edit_time: adjusted_time, blink_iteration: 0}}
  end

  defp verify_button_hold(press_start_time, adjustment_type, %{is_key_down: true, key_press_timer: ^press_start_time, activity_mode: :Viewing, main_time: time_val, alarm_setting: alarm_val, ui_pid: display_pid} = state) do
    is_stopwatch_running = case :gproc.lookup_values({:p, :l, :stopwatch_active}) do
      [] -> false
      _ -> true
    end

    if is_stopwatch_running do
      {:noreply, state}
    else
      if :gproc.lookup_values({:p, :l, :edit_mode}) == [] do
        :gproc.reg({:p, :l, :edit_mode})
      end

      case adjustment_type do
        :time_adjust ->
          GenServer.cast(display_pid, {:set_time_display, "EDITING"})
          Process.send_after(self(), :blink_animation, @blink_cycle_duration)

          {:noreply, %{
            state
            | activity_mode: :Editing,
              display_mode: :Clock,
              active_segment: :hour,
              is_display_on: true,
              blink_iteration: 0,
              temp_edit_time: time_val,
              last_event_time: nil
          }}

        :alarm_adjust ->
          GenServer.cast(display_pid, {:set_time_display, "EDIT ALARM"})
          Process.send_after(self(), :blink_animation, @blink_cycle_duration)

          {:noreply, %{
            state
            | activity_mode: :Editing,
              display_mode: :Alarm,
              active_segment: :hour,
              is_display_on: true,
              blink_iteration: 0,
              temp_edit_time: alarm_val,
              last_event_time: nil
          }}
      end
    end
  end

  defp verify_button_hold(_press_start, _adjust_type, state), do: {:noreply, state}

  defp update_editing_display(%{activity_mode: :Editing, is_display_on: current_on, ui_pid: display_pid, temp_edit_time: current_edit_val, active_segment: segment, blink_iteration: iter_count} = state) do
    new_on_status = !current_on
    next_iteration = if new_on_status, do: iter_count + 1, else: iter_count

    if next_iteration == @max_blink_repetitions do
      send(self(), :finalize_edit)
      {:noreply, state}
    else
      {h, m, s} = {current_edit_val.hour, current_edit_val.minute, current_edit_val.second}

      display_output =
        case segment do
          :hour -> "#{if(new_on_status, do: format_num(h), else: "  ")}:#{format_num(m)}:#{format_num(s)}"
          :minute -> "#{format_num(h)}:#{if(new_on_status, do: format_num(m), else: "  ")}:#{format_num(s)}"
          :second -> "#{format_num(h)}:#{format_num(m)}:#{if(new_on_status, do: format_num(s), else: "  ")}"
        end

      GenServer.cast(display_pid, {:set_time_display, display_output})
      Process.send_after(self(), :blink_animation, @blink_cycle_duration)

      {:noreply, %{state | is_display_on: new_on_status, blink_iteration: next_iteration}}
    end
  end

  defp update_editing_display(state), do: {:noreply, state}

  defp exit_editing_state(%{activity_mode: :Editing, temp_edit_time: final_value, ui_pid: display_pid, display_mode: mode_being_edited} = state) do
    update_ui_time(display_pid, final_value)
    :gproc.unreg({:p, :l, :edit_mode})

    result_state =
      case mode_being_edited do
        :Clock ->
          %{state | activity_mode: :Viewing, main_time: final_value, temp_edit_time: nil, active_segment: nil, is_display_on: false, blink_iteration: 0, display_mode: :Clock}

        :Alarm ->
          %{state | activity_mode: :Viewing, alarm_setting: final_value, temp_edit_time: nil, active_segment: nil, is_display_on: false, blink_iteration: 0, display_mode: :Clock}
      end

    {:noreply, result_state}
  end

  defp increment_time_part(time, :hour), do: %{time | hour: rem(time.hour + 1, 24)}
  defp increment_time_part(time, :minute), do: %{time | minute: rem(time.minute + 1, 60)}
  defp increment_time_part(time, :second), do: %{time | second: rem(time.second + 1, 60)}

  defp format_num(n) when n < 10, do: "0#{n}"
  defp format_num(n), do: "#{n}"

  defp update_ui_time(display_pid, time_value) do
    formatted_value = Time.truncate(time_value, :second) |> Time.to_string()
    GenServer.cast(display_pid, {:set_time_display, formatted_value})
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end
end
