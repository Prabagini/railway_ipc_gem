require "json"
require "base64"
require "railway_ipc/consumer/consumer_response_handlers"

module RailwayIpc
  class Consumer
    include Sneakers::Worker
    attr_reader :message, :handler

    def self.listen_to(queue:, exchange:)
      from_queue queue,
                 exchange: exchange,
                 durable: true,
                 exchange_type: :fanout,
                 connection: RailwayIpc.bunny_connection
    end

    def self.handle(message_type, with:)
      ConsumerResponseHandlers.instance.register(message: message_type, handler: with)
    end

    def registered_handlers
      ConsumerResponseHandlers.instance.registered
    end

    def work_with_params(payload, delivery_info, metadata)
      binding.pry
      # find of create a consumed message record
      # lock the database row
      # call the handler
      # record the status response from the handled message
      # unlock the database row
      decoded_payload = RailwayIpc::Rabbitmq::Payload.decode(payload)

      case decoded_payload.type
      when *registered_handlers
        @handler = handler_for(decoded_payload)
        message_klass = message_handler_for(decoded_payload)
        decoded_message = message_klass.decode(decoded_payload.message)
        # decoded_payload.message is the base64 encoded message
        # can be potentially used for future replay if handler didn't process or couldn't
        ConsumedMessage.persist_with_lock!(encoded_message: decoded_payload.message, decoded_message: decoded_message, type: message_klass) { handler.handle(message) }
      else
        message = RailwayIpc::BaseMessage.decode(decoded_payload.message)
        ConsumedMessage.persist_unknown_message_type(encoded_message: decoded_payload.message, decoded_message: decoded_message) # auto use type: RailwayIpc::NullMessage in method definition
      end

      rescue StandardError => e
        RailwayIpc.logger.log_exception(
          feature: "railway_consumer",
          error: e.class,
          error_message: e.message,
          payload: payload,
        )
        raise e
    end


    private

    def message_handler_for(decoded_payload)
      ConsumerResponseHandlers.instance.get(decoded_payload.type).message
    end

    def handler_for(decoded_payload)
      ConsumerResponseHandlers.instance.get(decoded_payload.type).handler.new
    end
  end
end
