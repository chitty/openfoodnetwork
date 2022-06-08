# frozen_string_literal: true

require 'spree/core/controller_helpers/order'
require 'open_food_network/tag_rule_applicator'

class BaseController < ApplicationController
  layout 'darkswarm'

  include Spree::Core::ControllerHelpers::Order

  include I18nHelper
  include OrderCyclesHelper

  before_action :set_locale

  private

  def all_distributor_order_cycles_invalid?
    OrderCycle.with_distributor(@distributor).active.all?(&:invalid?)
  end

  def set_order_cycles
    if !@distributor.ready_for_checkout? || all_distributor_order_cycles_invalid?
      @order_cycles = OrderCycle.where('false')
      return
    end

    @order_cycles = Shop::OrderCyclesList.new(@distributor, current_customer).call

    set_order_cycle
  end

  # Default to the only order cycle if there's only one
  #
  # Here we need to use @order_cycles.size not @order_cycles.count
  #   because OrderCyclesList returns a modified ActiveRecord::Relation
  #     and these modifications are not seen if it is reloaded with count
  def set_order_cycle
    return if @order_cycles.size != 1

    current_order(true).set_order_cycle! @order_cycles.first
  end
end
