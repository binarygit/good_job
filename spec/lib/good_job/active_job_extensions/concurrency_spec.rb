# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::ActiveJobExtensions::Concurrency do
  before do
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)

    stub_const 'JOB_PERFORMED', Concurrent::AtomicBoolean.new(false)
    stub_const 'TestJob', (Class.new(ActiveJob::Base) do
      include GoodJob::ActiveJobExtensions::Concurrency

      def perform(name:)
        name && sleep(1)
        JOB_PERFORMED.make_true
      end
    end)
  end

  describe 'when extension is only included but not configured' do
    it 'does not limit concurrency' do
      expect do
        TestJob.perform_later(name: "Alice")
        GoodJob.perform_inline
      end.not_to raise_error
    end
  end

  describe 'when concurrency key returns nil' do
    it 'does not limit concurrency' do
      TestJob.good_job_control_concurrency_with(
        total_limit: -> { 1 },
        key: -> {}
      )

      expect(TestJob.perform_later(name: "Alice")).to be_present
      expect(TestJob.perform_later(name: "Alice")).to be_present
    end
  end

  describe 'when concurrency key is nil' do
    it 'does not limit concurrency' do
      TestJob.good_job_control_concurrency_with(
        total_limit: -> { 1 },
        key: nil
      )

      expect(TestJob.perform_later(name: "Alice")).to be_present
      expect(TestJob.perform_later(name: "Alice")).to be_present
    end
  end

  describe '.good_job_control_concurrency_with' do
    describe 'total_limit:', :skip_rails_5 do
      before do
        TestJob.good_job_control_concurrency_with(
          total_limit: -> { 1 },
          key: -> { arguments.first[:name] }
        )
      end

      it "does not enqueue if limit is exceeded for a particular key" do
        expect(TestJob.perform_later(name: "Alice")).to be_present
        expect(TestJob.perform_later(name: "Alice")).to be false
      end

      it "is inclusive of both performing and enqueued jobs" do
        expect(TestJob.perform_later(name: "Alice")).to be_present

        Rails.application.executor.wrap do
          GoodJob::Execution.all.with_advisory_lock do
            expect(TestJob.perform_later(name: "Alice")).to be false
          end
        end
      end
    end

    describe 'enqueue_limit:', :skip_rails_5 do
      before do
        TestJob.good_job_control_concurrency_with(
          enqueue_limit: -> { 2 },
          key: -> { arguments.first[:name] }
        )
      end

      it "does not enqueue if enqueue concurrency limit is exceeded for a particular key" do
        allow(TestJob.logger.formatter).to receive(:call).and_call_original

        expect(TestJob.perform_later(name: "Alice")).to be_present
        expect(TestJob.perform_later(name: "Alice")).to be_present

        # Third usage of key does not enqueue
        expect(TestJob.perform_later(name: "Alice")).to be false

        # Usage of different key does enqueue
        expect(TestJob.perform_later(name: "Bob")).to be_present

        expect(GoodJob::Execution.where(concurrency_key: "Alice").count).to eq 2
        expect(GoodJob::Execution.where(concurrency_key: "Bob").count).to eq 1

        expect(TestJob.logger.formatter).to have_received(:call).with("INFO", anything, anything, a_string_matching(/Aborted enqueue of TestJob \(Job ID: .*\) because the concurrency key 'Alice' has reached its limit of 2 jobs/)).exactly(:once)
        if ActiveJob.gem_version >= Gem::Version.new("6.1.0")
          expect(TestJob.logger.formatter).to have_received(:call).with("INFO", anything, anything, a_string_matching(/Enqueued TestJob \(Job ID: .*\) to \(default\) with arguments: {:name=>"Alice"}/)).exactly(:twice)
          expect(TestJob.logger.formatter).to have_received(:call).with("INFO", anything, anything, a_string_matching(/Enqueued TestJob \(Job ID: .*\) to \(default\) with arguments: {:name=>"Bob"}/)).exactly(:once)
        end
      end

      it 'excludes jobs that are already executing/locked' do
        expect(TestJob.perform_later(name: "Alice")).to be_present
        expect(TestJob.perform_later(name: "Alice")).to be_present

        # Lock one of the jobs
        Rails.application.executor.wrap do
          GoodJob::Execution.first.with_advisory_lock do
            # Third usage does enqueue
            expect(TestJob.perform_later(name: "Alice")).to be_present
          end
        end
      end
    end

    describe 'perform_limit:' do
      before do
        allow(GoodJob).to receive(:preserve_job_records).and_return(true)

        TestJob.good_job_control_concurrency_with(
          perform_limit: -> { 0 },
          key: -> { arguments.first[:name] }
        )
      end

      it "will error and retry jobs if concurrency is exceeded" do
        active_job = TestJob.perform_later(name: "Alice")

        performer = GoodJob::JobPerformer.new('*')
        scheduler = GoodJob::Scheduler.new(performer, max_threads: 5)
        5.times { scheduler.create_thread }

        sleep_until(max: 10, increments_of: 0.5) do
          GoodJob::DiscreteExecution.where(active_job_id: active_job.job_id).finished.count >= 1
        end
        scheduler.shutdown

        expect(GoodJob::Job.find_by(active_job_id: active_job.job_id).concurrency_key).to eq "Alice"

        expect(GoodJob::DiscreteExecution.count).to be >= 1
        expect(GoodJob::DiscreteExecution.where("error LIKE '%GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError%'")).to be_present
      end

      it 'is ignored with the job is executed via perform_now' do
        TestJob.perform_now(name: "Alice")
        expect(JOB_PERFORMED).to be_true
      end
    end
  end

  describe '#good_job_concurrency_key' do
    context 'when retrying a job' do
      before do
        stub_const 'TestJob', (Class.new(ActiveJob::Base) do
          include GoodJob::ActiveJobExtensions::Concurrency

          good_job_control_concurrency_with(
            total_limit: 1,
            key: -> { Time.current.to_f }
          )
          retry_on StandardError

          def perform
            raise "ERROR"
          end
        end)
      end

      describe 'retries' do
        it 'preserves the value' do
          TestJob.set(wait_until: 5.minutes.ago).perform_later(name: "Alice")

          begin
            GoodJob.perform_inline
          rescue StandardError
            nil
          end

          expect(GoodJob::Execution.count).to eq 1
          expect(GoodJob::Execution.first.concurrency_key).to be_present
          expect(GoodJob::Job.first).not_to be_finished
        end

        context 'when not discrete' do
          it 'preserves the key value across retries' do
            TestJob.set(wait_until: 5.minutes.ago).perform_later(name: "Alice")
            GoodJob::Job.first.update!(is_discrete: false)

            begin
              GoodJob.perform_inline
            rescue StandardError
              nil
            end

            expect(GoodJob::Execution.count).to eq 2
            first_execution, retried_execution = GoodJob::Execution.order(created_at: :asc).to_a
            expect(retried_execution.concurrency_key).to eq first_execution.concurrency_key
          end
        end
      end
    end

    context 'when no key is specified' do
      before do
        stub_const 'TestJob', (Class.new(ActiveJob::Base) do
          include GoodJob::ActiveJobExtensions::Concurrency

          def perform(name)
          end
        end)
      end

      it 'uses the class name as the default concurrency key' do
        job = TestJob.perform_later("Alice")
        expect(job.good_job_concurrency_key).to eq('TestJob')
      end
    end

    describe '#perform_later' do
      before do
        stub_const 'TestJob', (Class.new(ActiveJob::Base) do
          include GoodJob::ActiveJobExtensions::Concurrency

          good_job_control_concurrency_with(
            total_limit: 1,
            key: -> { arguments.first }
          )

          def perform(arg)
          end
        end)
      end

      it 'raises an error for non-serializable types' do
        expect { TestJob.perform_later({ key: "value" }) }.to raise_error(TypeError, "Concurrency key must be a String; was a Hash")
        expect { TestJob.perform_later({ key: "value" }.with_indifferent_access) }.to raise_error(TypeError)
        expect { TestJob.perform_later(["key"]) }.to raise_error(TypeError)
        expect { TestJob.perform_later(TestJob) }.to raise_error(TypeError)
      end
    end
  end
end
