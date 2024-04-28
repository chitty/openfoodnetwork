# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CheckoutController, type: :controller do
  let(:user) { order.user }
  let(:address) { create(:address) }
  let(:distributor) { create(:distributor_enterprise, with_payment_and_shipping: true) }
  let(:order_cycle) { create(:order_cycle, distributors: [distributor]) }
  let(:exchange) { order_cycle.exchanges.outgoing.first }
  let(:order) { create(:order_with_line_items, line_items_count: 1, distributor:, order_cycle:) }
  let(:payment_method) { distributor.payment_methods.first }
  let(:stripe_payment_method) {
    create(:stripe_sca_payment_method, distributor_ids: [distributor.id], environment: Rails.env)
  }
  let(:shipping_method) { distributor.shipping_methods.first }

  before do
    exchange.variants << order.line_items.first.variant
    allow(controller).to receive(:current_order) { order }
    allow(controller).to receive(:spree_current_user) { user }
  end

  describe "#edit" do
    it "renders the checkout" do
      get :edit, params: { step: "details" }
      expect(response.status).to eq 200
    end

    it "redirects to current step if no step is given" do
      get :edit
      expect(response).to redirect_to checkout_step_path(:details)
    end

    context "when line items in the cart are not valid" do
      before { allow(controller).to receive(:valid_order_line_items?) { false } }

      it "redirects to cart" do
        get :edit
        expect(response).to redirect_to cart_path
      end
    end

    context "when the given `step` params is inconsistent with the current order state" do
      context "when order state is `cart`" do
        before do
          order.update!(state: "cart")
        end

        it "redirects to the valid step if params is `payment`" do
          get :edit, params: { step: "payment" }
          expect(response).to redirect_to checkout_step_path(:details)
        end
        it "redirects to the valid step if params is `summary`" do
          get :edit, params: { step: "summary" }
          expect(response).to redirect_to checkout_step_path(:details)
        end
      end

      context "when order state is `payment`" do
        before do
          order.update!(state: "payment")
        end

        it "redirects to the valid step if params is `summary`" do
          get :edit, params: { step: "summary" }
          expect(response).to redirect_to checkout_step_path(:payment)
        end
      end

      context "when order state is 'confirmation'" do
        before do
          order.update!(state: "confirmation")
        end

        context "when loading payment step" do
          it "updates the order state to payment" do
            get :edit, params: { step: "payment" }

            expect(response.status).to eq 200
            expect(order.reload.state).to eq("payment")
          end
        end

        context "when loading address step" do
          it "updates the order state to address" do
            get :edit, params: { step: "details" }

            expect(response.status).to eq 200
            expect(order.reload.state).to eq("address")
          end
        end
      end

      context "when order state is 'payment'" do
        context "when loading address step" do
          before do
            order.update!(state: "payment")
          end

          it "updates the order state to address" do
            get :edit, params: { step: "details" }

            expect(response.status).to eq 200
            expect(order.reload.state).to eq("address")
          end
        end
      end
    end
  end

  describe "#update" do
    let(:checkout_params) { {} }
    let(:params) { { step: }.merge(checkout_params) }

    context "details step" do
      let(:step) { "details" }

      context "with incomplete data" do
        let(:checkout_params) { { order: { email: user.email } } }

        it "returns 422 and some feedback" do
          put(:update, params:)

          expect(response.status).to eq 422
          expect(flash[:error]).to match "Saving failed, please update the highlighted fields."
          expect(order.reload.state).to eq "cart"
        end
      end

      context "with complete data" do
        let(:checkout_params) do
          {
            order: {
              email: user.email,
              bill_address_attributes: address.to_param,
              ship_address_attributes: address.to_param
            },
            shipping_method_id: shipping_method.id
          }
        end

        it "updates and redirects to payment step" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:payment)
          expect(order.reload.state).to eq "payment"
        end

        describe "saving default addresses" do
          it "doesn't update default bill address on user" do
            expect {
              put :update, params: params.merge(order: { save_bill_address: "0" })
            }.not_to change {
              order.user.reload.bill_address
            }
          end

          it "updates default bill address on user and customer" do
            put :update, params: params.merge(order: { save_bill_address: "1" })

            expect(order.customer.bill_address).to eq(order.bill_address)
            expect(order.user.bill_address).to eq(order.bill_address)
          end

          it "doesn't update default ship address on user" do
            expect {
              put :update, params: params.merge(order: { save_ship_address: "0" })
            }.not_to change {
              order.user.reload.ship_address
            }
          end

          it "updates default ship address on user and customer" do
            put :update, params: params.merge(order: { save_ship_address: "1" })

            expect(order.customer.ship_address).to eq(order.ship_address)
            expect(order.user.ship_address).to eq(order.ship_address)
          end
        end

        describe "with a voucher" do
          let(:checkout_params) do
            {
              order: {
                email: user.email,
                bill_address_attributes: address.to_param,
                ship_address_attributes: address.to_param
              },
              shipping_method_id: order.shipment.shipping_method.id.to_s
            }
          end

          let(:voucher) { create(:voucher_flat_rate, enterprise: distributor) }
          let(:service) { mock_voucher_adjustment_service }

          before do
            voucher.create_adjustment(voucher.code, order)
          end

          it "doesn't recalculate the voucher adjustment" do
            expect(service).not_to receive(:update)

            put(:update, params:)

            expect(response).to redirect_to checkout_step_path(:payment)
          end

          context "when updating shipping method" do
            let(:checkout_params) do
              {
                order: {
                  email: user.email,
                  bill_address_attributes: address.to_param,
                  ship_address_attributes: address.to_param
                },
                shipping_method_id: new_shipping_method.id.to_s
              }
            end
            let(:new_shipping_method) { create(:shipping_method, distributors: [distributor]) }

            before do
              # Add a shipping rates for the new shipping method to prevent
              # order.select_shipping_method from failing
              order.shipment.shipping_rates <<
                Spree::ShippingRate.create(shipping_method: new_shipping_method, selected: true)
            end

            it "recalculates the voucher adjustment" do
              expect(service).to receive(:update)

              put(:update, params:)

              expect(response).to redirect_to checkout_step_path(:payment)
            end

            context "when no shipments available" do
              before do
                order.shipments.destroy_all
              end

              it "recalculates the voucher adjustment" do
                expect(service).to receive(:update)

                put(:update, params:)

                expect(response).to redirect_to checkout_step_path(:payment)
              end
            end
          end
        end
      end
    end

    context "payment step" do
      let(:step) { "payment" }

      before do
        order.bill_address = address
        order.ship_address = address
        order.select_shipping_method shipping_method.id
        Orders::WorkflowService.new(order).advance_to_payment
      end

      context "with incomplete data" do
        let(:checkout_params) { { order: { email: user.email } } }

        it "returns 422 and some feedback" do
          put(:update, params:)

          expect(response.status).to eq 422
          expect(flash[:error]).to match "Saving failed, please update the highlighted fields."
          expect(order.reload.state).to eq "payment"
        end
      end

      context "with complete data" do
        let(:checkout_params) do
          {
            order: {
              payments_attributes: [
                { payment_method_id: payment_method.id }
              ]
            }
          }
        end

        it "updates and redirects to summary step" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:summary)
          expect(order.reload.state).to eq "confirmation"
          expect(response.status).to be 302
        end

        describe "with a voucher" do
          let(:voucher) { create(:voucher_flat_rate, enterprise: distributor) }

          before do
            voucher.create_adjustment(voucher.code, order)
          end

          # so we need to recalculate voucher to account for payment fees
          it "recalculates the voucher adjustment" do
            service = mock_voucher_adjustment_service
            expect(service).to receive(:update)

            put(:update, params:)

            expect(response).to redirect_to checkout_step_path(:summary)
          end
        end
      end

      context "with no payment source" do
        let(:checkout_params) do
          {
            order: {
              payments_attributes: [
                { payment_method_id: stripe_payment_method.id }
              ]
            }
          }
        end

        it "updates and redirects to summary step" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:summary)
          expect(order.reload.state).to eq "confirmation"
          expect(order.payments.first.source).to eq nil
          expect(response.status).to be 302
        end
      end

      context "with payment fees" do
        let(:payment_method_with_fee) do
          create(:payment_method, :flat_rate, amount: "1.23", distributors: [distributor])
        end
        let(:checkout_params) do
          {
            order: {
              payments_attributes: [
                { payment_method_id: payment_method_with_fee.id }
              ]
            }
          }
        end

        it "applies the fee and updates the order total" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:summary)

          order.reload

          expect(order.state).to eq "confirmation"
          expect(order.payments.first.adjustment.amount).to eq 1.23
          expect(order.payments.first.amount).to eq order.item_total + order.adjustment_total
          expect(order.adjustment_total).to eq 1.23
          expect(order.total).to eq order.item_total + order.adjustment_total
        end
      end

      context "with a zero-priced order" do
        let(:params) do
          { step: "payment", order: { payments_attributes: [{ amount: 0 }] } }
        end

        before do
          order.line_items.first.update(price: 0)
          order.update_totals_and_states
        end

        it "allows proceeding to confirmation" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:summary)
          expect(order.reload.state).to eq "confirmation"
          expect(order.payments.count).to eq 1
          expect(order.payments.first.amount).to eq 0
        end
      end

      context "with a saved credit card" do
        let!(:saved_card) { create(:stored_credit_card, user:) }
        let(:checkout_params) do
          {
            order: {
              payments_attributes: [
                { payment_method_id: payment_method.id }
              ]
            },
            existing_card_id: saved_card.id
          }
        end

        it "updates and redirects to payment step" do
          put(:update, params:)

          expect(response).to redirect_to checkout_step_path(:summary)
          expect(order.reload.state).to eq "confirmation"
          expect(order.payments.first.source.id).to eq saved_card.id
        end
      end
    end

    context "summary step" do
      let(:step) { "summary" }

      before do
        order.bill_address = address
        order.ship_address = address
        order.select_shipping_method shipping_method.id
        Orders::WorkflowService.new(order).advance_to_payment

        order.payments << build(:payment, amount: order.total, payment_method:)
        order.next
      end

      describe "confirming the order" do
        it "completes the order and redirects to order confirmation" do
          put(:update, params:)

          expect(response).to redirect_to order_path(order, order_token: order.token)
          expect(order.reload.state).to eq "complete"
        end
      end

      context "when accepting T&Cs is required" do
        before do
          allow(TermsOfService).to receive(:platform_terms_required?) { true }
        end

        describe "submitting without accepting the T&Cs" do
          let(:checkout_params) { {} }

          it "returns 422 and some feedback" do
            put(:update, params:)

            expect(response.status).to eq 422
            expect(flash[:error]).to match "Saving failed, please update the highlighted fields."
            expect(order.reload.state).to eq "confirmation"
          end
        end

        describe "submitting and accepting the T&Cs" do
          let(:checkout_params) { { accept_terms: true } }

          it "completes the order and redirects to order confirmation" do
            put(:update, params:)

            expect(response).to redirect_to order_path(order, order_token: order.token)
            expect(order.reload.state).to eq "complete"
          end
        end
      end

      context "when an external payment gateway is used" do
        before do
          expect(Checkout::PaymentMethodFetcher).
            to receive_message_chain(:new, :call) { payment_method }
          expect(payment_method).to receive(:external_gateway?) { true }
          expect(payment_method).to receive(:external_payment_url) { "https://example.com/pay" }
        end

        describe "confirming the order" do
          it "redirects to the payment gateway's URL" do
            put(:update, params:)

            expect(response.body).to match("https://example.com/pay").and match("redirect")
            expect(order.reload.state).to eq "confirmation"
          end
        end
      end
    end
  end

  describe "running out of stock" do
    let(:order_cycle_distributed_variants) { double(:order_cycle_distributed_variants) }

    before do
      allow(controller).to receive(:current_order).and_return(order)
      allow(order).to receive(:distributor).and_return(distributor)
      order.update(order_cycle:)

      allow(OrderCycles::DistributedVariantsService).to receive(:new).and_return(
        order_cycle_distributed_variants
      )
    end

    shared_examples "handling stock issues" do |step|
      context "#{step} step" do
        let(:step) { step.to_s }

        it "redirects when some items are out of stock" do
          allow(order).to receive_message_chain(:insufficient_stock_lines, :empty?).and_return false

          get :edit
          expect(response).to redirect_to cart_path
        end

        it "redirects when some items are not available" do
          allow(order).to receive_message_chain(:insufficient_stock_lines, :empty?).and_return true
          expect(order_cycle_distributed_variants).to receive(
            :distributes_order_variants?
          ).with(order).and_return(false)

          get :edit
          expect(response).to redirect_to cart_path
        end
      end
    end

    it_behaves_like "handling stock issues", "details"
    it_behaves_like "handling stock issues", "payment"
    it_behaves_like "handling stock issues", "summary"
  end

  def mock_voucher_adjustment_service
    voucher_adjustment_service = instance_double(VoucherAdjustmentsService)
    allow(VoucherAdjustmentsService).to receive(:new).and_return(voucher_adjustment_service)

    voucher_adjustment_service
  end
end
