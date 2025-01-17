# frozen_string_literal: true
module Dynflow
  module Action::WithBulkSubPlans
    include Dynflow::Action::Cancellable

    DEFAULT_BATCH_SIZE = 100

    # Should return a slice of size items starting from item with index from
    def batch(from, size)
      raise NotImplementedError
    end

    PlanNextBatch = Algebrick.atom

    def run(event = nil)
      if event === PlanNextBatch
        if can_spawn_next_batch?
          spawn_plans
          suspend
        else
          on_planning_finished
        end
      else
        super
      end
    end

    def on_planning_finished
      suspend
    end

    def initiate
      output[:planned_count] = 0
      output[:cancelled_count] = 0
      output[:total_count] = total_count
      super
    end

    def increase_counts(planned, failed)
      super(planned, failed, false)
      output[:planned_count] += planned + failed
    end

    # Should return the expected total count of tasks
    def total_count
      raise NotImplementedError
    end

    # Returns the items in the current batch
    def current_batch
      start_position = output[:planned_count]
      size = start_position + batch_size > total_count ? total_count - start_position : batch_size
      batch(start_position, size)
    end

    def batch_size
      DEFAULT_BATCH_SIZE
    end

    # The same logic as in Action::WithSubPlans, but calculated using the expected total count
    def run_progress
      if counts_set? && total_count > 0
        sum = output.values_at(:success_count, :cancelled_count, :failed_count).reduce(:+)
        sum.to_f / total_count
      else
        0.1
      end
    end

    def spawn_plans
      super
    ensure
      suspended_action << PlanNextBatch
    end

    def cancel!(force = false)
      # Count the not-yet-planned tasks as cancelled
      output[:cancelled_count] = total_count - output[:planned_count]
      if uses_concurrency_control
        # Tell the throttle limiter to cancel the tasks its managing
        world.throttle_limiter.cancel!(execution_plan_id)
      else
        # Just stop the tasks which were not started yet
        sub_plans(:state => 'planned').each { |sub_plan| sub_plan.update_state(:stopped) }
      end
      # Pass the cancel event to running sub plans if they can be cancelled
      sub_plans(:state => 'running').each { |sub_plan| sub_plan.cancel(force) if sub_plan.cancellable? }
      suspend
    end

    private

    def done?
      !can_spawn_next_batch? && super
    end

    def can_spawn_next_batch?
      remaining_count > 0
    end

    def remaining_count
      total_count - output[:cancelled_count] - output[:planned_count]
    end
  end
end
