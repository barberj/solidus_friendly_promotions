# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusFriendlyPromotions::FriendlyPromotionAdjuster::DiscountOrder do
  context "shipped orders" do
    let(:promotions) { [] }
    let(:order) { create(:order, shipment_state: "shipped") }

    subject { described_class.new(order, promotions).call }

    it "returns the order unmodified" do
      expect(order).not_to receive(:reset_current_discounts)
      expect(subject).to eq(order)
    end
  end

  describe "discounting orders" do
    let(:shirt) { create(:product, name: "Shirt") }
    let(:order) { create(:order_with_line_items, line_items_attributes: [{variant: shirt.master, quantity: 1}]) }
    let!(:promotion) { create(:friendly_promotion, :with_free_shipping, name: "20% off Shirts", apply_automatically: true) }
    let(:promotions) { [promotion] }
    let(:discounter) { described_class.new(order, promotions) }

    subject { discounter.call }

    before do
      order.shipments.first.shipping_rates.first.update!(cost: nil)
    end

    it "does not blow up if the shipping rate cost is nil" do
      expect { subject }.not_to raise_exception
    end
  end

  describe "collecting eligibility results in a dry run" do
    let(:shirt) { create(:product, name: "Shirt") }
    let(:order) { create(:order_with_line_items, line_items_attributes: [{variant: shirt.master, quantity: 1}]) }
    let(:rules) { [product_rule] }
    let!(:promotion) { create(:friendly_promotion, :with_adjustable_action, rules: rules, name: "20% off Shirts", apply_automatically: true) }
    let(:product_rule) { SolidusFriendlyPromotions::Rules::Product.new(products: [shirt], preferred_line_item_applicable: false) }
    let(:promotions) { [promotion] }
    let(:discounter) { described_class.new(order, promotions, dry_run: true) }

    subject { discounter.call }

    it "will collect eligibility results" do
      subject

      expect(promotion.eligibility_results.first.success).to be true
      expect(promotion.eligibility_results.first.code).to be nil
      expect(promotion.eligibility_results.first.rule).to eq(product_rule)
      expect(promotion.eligibility_results.first.message).to be nil
      expect(promotion.eligibility_results.first.item).to eq(order)
    end

    it "can tell us about success" do
      subject
      expect(promotion.eligibility_results.success?).to be true
    end

    context "with two rules" do
      let(:rules) { [product_rule, item_total_rule] }
      let(:item_total_rule) { SolidusFriendlyPromotions::Rules::ItemTotal.new(preferred_amount: 2000) }

      it "will collect eligibility results" do
        subject

        expect(promotion.eligibility_results.first.success).to be true
        expect(promotion.eligibility_results.first.code).to be nil
        expect(promotion.eligibility_results.first.rule).to eq(product_rule)
        expect(promotion.eligibility_results.first.message).to be nil
        expect(promotion.eligibility_results.first.item).to eq(order)
        expect(promotion.eligibility_results.last.success).to be false
        expect(promotion.eligibility_results.last.rule).to eq(item_total_rule)
        expect(promotion.eligibility_results.last.code).to eq :item_total_less_than_or_equal
        expect(promotion.eligibility_results.last.message).to eq "This coupon code can't be applied to orders less than or equal to $2,000.00."
        expect(promotion.eligibility_results.last.item).to eq(order)
      end

      it "can tell us about success" do
        subject
        expect(promotion.eligibility_results.success?).to be false
      end

      it "has errors for this promo" do
        subject
        expect(promotion.eligibility_results.error_messages).to eq([
          "This coupon code can't be applied to orders less than or equal to $2,000.00."
        ])
      end
    end

    context "with an order with multiple line items and an item-level rule" do
      let(:pants) { create(:product, name: "Pants") }
      let(:order) do
        create(
          :order_with_line_items,
          line_items_attributes: [{variant: shirt.master, quantity: 1}, {variant: pants.master, quantity: 1}]
        )
      end

      let(:shirt_product_rule) { SolidusFriendlyPromotions::Rules::LineItemProduct.new(products: [shirt]) }
      let(:rules) { [shirt_product_rule] }

      it "can tell us about success" do
        subject
        # This is successful, because one of the line item rules matches
        expect(promotion.eligibility_results.success?).to be true
      end

      it "has no errors for this promo" do
        subject
        expect(promotion.eligibility_results.error_messages).to be_empty
      end

      context "with a second line item level rule" do
        let(:hats) { create(:taxon, name: "Hats", products: [hat]) }
        let(:hat) { create(:product) }
        let(:hat_product_rule) { SolidusFriendlyPromotions::Rules::LineItemTaxon.new(taxons: [hats]) }
        let(:rules) { [shirt_product_rule, hat_product_rule] }

        it "can tell us about success" do
          subject
          expect(promotion.eligibility_results.success?).to be false
        end

        it "has errors for this promo" do
          subject
          expect(promotion.eligibility_results.error_messages).to eq([
            "This coupon code could not be applied to the cart at this time."
          ])
        end
      end
    end

    context "when the order must not contain a shirt" do
      let(:no_shirt_rule) { SolidusFriendlyPromotions::Rules::Product.new(products: [shirt], preferred_match_policy: "none", preferred_line_item_applicable: false) }
      let(:rules) { [no_shirt_rule] }

      it "can tell us about success" do
        subject
        # This is successful, because the order has a shirt
        expect(promotion.eligibility_results.success?).to be false
      end
    end

    context "where one action succeeds and another errors" do
      let(:usps) { create(:shipping_method) }
      let(:ups_ground) { create(:shipping_method) }
      let(:order) { create(:order_with_line_items, line_items_attributes: [{variant: shirt.master, quantity: 1}], shipping_method: ups_ground) }
      let(:product_rule) { SolidusFriendlyPromotions::Rules::Product.new(products: [shirt], preferred_line_item_applicable: false) }
      let(:shipping_method_rule) { SolidusFriendlyPromotions::Rules::ShippingMethod.new(preferred_shipping_method_ids: [usps.id]) }
      let(:ten_off_items) { SolidusFriendlyPromotions::Calculators::Percent.create!(preferred_percent: 10) }
      let(:ten_off_shipping) { SolidusFriendlyPromotions::Calculators::Percent.create!(preferred_percent: 10) }
      let(:shipping_action) { SolidusFriendlyPromotions::Actions::AdjustShipment.new(calculator: ten_off_shipping) }
      let(:line_item_action) { SolidusFriendlyPromotions::Actions::AdjustLineItem.new(calculator: ten_off_items) }
      let(:actions) { [shipping_action, line_item_action] }
      let(:rules) { [product_rule, shipping_method_rule] }
      let!(:promotion) { create(:friendly_promotion, actions: actions, rules: rules, name: "10% off Shirts and USPS Shipping", apply_automatically: true) }

      it "can tell us about success" do
        subject
        expect(promotion.eligibility_results.success?).to be true
      end

      it "can tell us about errors" do
        subject
        expect(promotion.eligibility_results.error_messages).to eq(["This coupon code could not be applied to the cart at this time."])
      end
    end

    context "with no rules" do
      let(:rules) { [] }

      it "has no errors for this promo" do
        subject
        expect(promotion.eligibility_results.error_messages).to be_empty
      end
    end

    context "with an ineligible order-level rule" do
      let(:mug) { create(:product) }
      let(:order_rule) { SolidusFriendlyPromotions::Rules::NthOrder.new(preferred_nth_order: 2) }
      let(:line_item_rule) { SolidusFriendlyPromotions::Rules::LineItemProduct.new(products: [mug]) }
      let(:rules) { [order_rule, line_item_rule] }

      it "can tell us about success" do
        subject
        expect(promotion.eligibility_results.success?).to be false
      end

      it "can tell us about all the errors", :pending do
        subject
        expect(promotion.eligibility_results.error_messages).to eq(
          [
            "This coupon code could not be applied to the cart at this time.",
            "You need to add an applicable product before applying this coupon code."
          ]
        )
      end
    end
  end
end
