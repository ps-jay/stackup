require "aws-sdk-resources"
require "stackup/errors"
require "stackup/stack_event_monitor"

module Stackup

  # An abstraction of a CloudFormation stack.
  #
  class Stack

    SUCESS_STATES = ["CREATE_COMPLETE", "DELETE_COMPLETE", "UPDATE_COMPLETE"]
    FAILURE_STATES = ["CREATE_FAILED", "DELETE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "UPDATE_ROLLBACK_COMPLETE", "UPDATE_ROLLBACK_FAILED"]
    END_STATES = SUCESS_STATES + FAILURE_STATES

    def initialize(name, client_or_options = {})
      @name = name
      if client_or_options.is_a?(Hash)
        @cf_client = Aws::CloudFormation::Client.new(client_or_options)
      else
        @cf_client = client_or_options
      end
      @cf_stack = Aws::CloudFormation::Stack.new(:name => name, :client => cf_client)
      @event_monitor = Stackup::StackEventMonitor.new(@cf_stack)
      @event_monitor.zero # drain previous events
    end

    attr_reader :name, :cf_client, :cf_stack, :event_monitor

    def status
      cf_stack.stack_status
    rescue Aws::CloudFormation::Errors::ValidationError => e
      handle_validation_error(e)
    end

    def exists?
      cf_stack.stack_status
      true
    rescue Aws::CloudFormation::Errors::ValidationError
      false
    end

    def create(template, parameters)
      cf_client.create_stack(
        :stack_name => name,
        :template_body => template,
        :disable_rollback => true,
        :capabilities => ["CAPABILITY_IAM"],
        :parameters => parameters
      )
      status = wait_for_events

      fail StackUpdateError, "stack creation failed" unless status == "CREATE_COMPLETE"
      true

    rescue ::Aws::CloudFormation::Errors::ValidationError
      return false
    end

    def update(template, parameters)
      return false unless exists?
      if cf_stack.stack_status == "CREATE_FAILED"
        puts "Stack is in CREATE_FAILED state so must be manually deleted before it can be updated"
        return false
      end
      if cf_stack.stack_status == "ROLLBACK_COMPLETE"
        deleted = delete
        return false if !deleted
      end
      cf_client.update_stack(:stack_name => name, :template_body => template, :parameters => parameters, :capabilities => ["CAPABILITY_IAM"])

      status = wait_for_events
      fail StackUpdateError, "stack update failed" unless status == "UPDATE_COMPLETE"
      true

    rescue ::Aws::CloudFormation::Errors::ValidationError => e
      if e.message == "No updates are to be performed."
        puts e.message
        return false
      end
      raise e
    end

    def delete
      cf_client.delete_stack(:stack_name => name)
      status = wait_for_events
      fail StackUpdateError, "stack delete failed" unless status == "DELETE_COMPLETE"
      true
    rescue Aws::CloudFormation::Errors::ValidationError => e
      handle_validation_error(e)
    end

    def deploy(template, parameters = [])
      if exists?
        update(template, parameters)
      else
        create(template, parameters)
      end
    rescue Aws::CloudFormation::Errors::ValidationError => e
      handle_validation_error(e)
    end

    # Returns a Hash of stack outputs.
    #
    def outputs
      {}.tap do |h|
        cf_stack.outputs.each do |output|
          h[output.output_key] = output.output_value
        end
      end
    rescue Aws::CloudFormation::Errors::ValidationError => e
      handle_validation_error(e)
    end

    def valid?(template)
      response = cf_client.validate_template(template)
      response[:code].nil?
    end

    private

    # Wait (displaying stack events) until the stack reaches a stable state.
    #
    def wait_for_events
      loop do
        display_new_events
        cf_stack.reload
        return status if status.nil? || status =~ /_(COMPLETE|FAILED)$/
        sleep(2)
      end
    end

    def display_new_events
      event_monitor.new_events.each do |e|
        ts = e.timestamp.localtime.strftime("%H:%M:%S")
        fields = [e.logical_resource_id, e.resource_status, e.resource_status_reason]
        puts("[#{ts}] #{fields.compact.join(' - ')}")
      end
    end

    def handle_validation_error(e)
      fail NoSuchStack, "no such stack: #{name}" if e.message.end_with?(" does not exist")
      raise e
    end

  end

end
