module Properties
  module Reportable
    extend ActiveSupport::Concern

    def summary(start = nil, stop = nil, paid: true)
      report = DailySummaryReport.scoped_by(self)
        .where(impressionable_type: "Campaign", impressionable_id: campaign_ids_relation(paid))
        .where(scoped_by_type: "Property", scoped_by_id: id)
        .between(start, stop)
        .load

      DailySummaryReport.new(
        impressions_count: report.sum(&:impressions_count),
        clicks_count: report.sum(&:clicks_count),
        gross_revenue_cents: report.sum(&:gross_revenue_cents),
        property_revenue_cents: report.sum(&:property_revenue_cents),
        house_revenue_cents: report.sum(&:house_revenue_cents)
      )
    end

    def earnings(start = nil, stop = nil)
      Money.new daily_summaries.scoped_by(nil).between(start, stop).sum(:property_revenue_cents)
    end

    # Returns the average RPM (revenue per mille)
    def average_rpm(start = nil, stop = nil)
      s = summary(start, stop)
      return Money.new(0, "USD") unless s.impressions_count > 0
      return Money.new(0, "USD") unless s.property_revenue.is_a?(Money)
      s.property_revenue / (s.impressions_count / 1000.to_f)
    rescue => e
      Rollbar.error e
      Money.new 0, "USD"
    end

    # Returns a Hash keyed as: Region => Money
    # where the value is the average RPM for the region
    def average_rpm_by_region(start = nil, stop = nil)
      region_summaries(start, stop).each_with_object({}) do |(region, summaries), memo|
        mille = summaries.sum(&:paid_impressions_count) / 1000.to_f
        property_revenue = summaries.sum(&:property_revenue)
        memo[region] = mille > 0 ? property_revenue / mille : Money.new(0)
      end
    end

    # Returns an ActiveRecord relation for DailySummaryReports scoped to country
    def country_summaries(start = nil, stop = nil)
      DailySummaryReport
        .scoped_by_type(:country_code)
        .where(impressionable_type: "Property", impressionable_id: id)
        .between(start, stop)
    end

    # Returns a Hash keyed as: Region => [DailySummaryReport, ...]
    # where the list is comprised of DailySummaryReports scoped to country
    def region_summaries(start = nil, stop = nil)
      country_summaries(start, stop).each_with_object({}) do |summary, memo|
        region = Rails.local_ephemeral_cache.fetch("region_for_country/#{summary.scoped_by_id}") {
          Region.with_all_country_codes(summary.scoped_by_id).first
        }
        memo[region] ||= []
        memo[region] << summary
      end
    end

    # Daily report -------------------------------------------------------------------------------------------

    def daily_summaries_by_day(start = nil, stop = nil, paid: true)
      DailySummary.scoped_by(self)
        .select(:displayed_at_date)
        .select(DailySummary.arel_table[:unique_ip_addresses_count].sum.as("unique_ip_addresses_count"))
        .select(DailySummary.arel_table[:impressions_count].sum.as("impressions_count"))
        .select(DailySummary.arel_table[:clicks_count].sum.as("clicks_count"))
        .select(DailySummary.arel_table[:gross_revenue_cents].sum.as("gross_revenue_cents"))
        .select(DailySummary.arel_table[:property_revenue_cents].sum.as("property_revenue_cents"))
        .select(DailySummary.arel_table[:house_revenue_cents].sum.as("house_revenue_cents"))
        .where(impressionable_type: "Campaign", impressionable_id: campaign_ids_relation(paid))
        .between(start, stop)
        .group(:displayed_at_date)
        .order(:displayed_at_date)
    end

    # Country report -----------------------------------------------------------------------------------------

    # def daily_summary_reports_by_country_code(start = nil, stop = nil)
    #   daily_summary_reports.scoped_by_type("country_code").between(start || start_date, stop || end_date)
    # end

    # Campaign report ----------------------------------------------------------------------------------------

    def daily_summary_reports_by_campaign(start = nil, stop = nil)
      daily_summary_reports.scoped_by_type("Campaign").between(start || start_date, stop || end_date)
    end

    private

    def campaign_ids_relation(paid = true)
      paid ? Campaign.premium : Campaign.fallback.or(Campaign.paid_fallback)
    end
  end
end
