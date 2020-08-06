# frozen_string_literal: true

module Jobs
  class ProcessGroupedAlerts < ::Jobs::Base
    sidekiq_options retry: false

    include AlertPostMixin

    STALE_DURATION = 5.freeze

    def execute(args)
      token = args[:token]
      data = JSON.parse(args[:data])

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      if data[0]&.key?("blocks")
        # Data from {{alertmanager}}/api/v1/alerts/grouped (removed in alertmanager v0.16.0)
        current_alerts = current_alerts(data)
      else
        # Data from {{alertmanager}}/api/v1/alerts
        current_alerts = data
      end

      update_open_alerts(receiver, current_alerts, args.slice(:graph_url, :logs_url, :grafana_url))
    end

    private

    def alert_history_key
      DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
    end

    def current_alerts(data)
      @current_alerts ||= begin
        alerts = []

        data.each do |group|
          group["blocks"].each do |block|
            alerts.concat(block["alerts"])
          end
        end

        alerts
      end
    end

    def normalize_status(status)
      return "firing" if status == "active"
      status
    end

    def update_open_alerts(receiver, active_alerts, opts)
      Topic.open_alerts.each do |topic|
        DistributedMutex.synchronize("prom_alert_receiver_topic_#{topic.id}") do
          alertname = receiver["topic_map"].key(topic.id)
          next unless alertname

          stored_alerts = topic.custom_fields.dig(alert_history_key, 'alerts')
          updated = false

          stored_alerts&.each do |stored_alert|
            stored_alert['logs_url'] ||= opts[:logs_url] if opts[:logs_url].present?

            if stored_alert['graph_url'].include?(opts[:graph_url]) && stored_alert['status'] != 'resolved'
              active_alert = active_alerts.find { |a| a['labels']['id'] == stored_alert['id'] && a['labels']['alertname'] == alertname }

              grafana_dashboard_url = get_grafana_dashboard_url(active_alert, opts[:grafana_url])
              stored_alert['grafana_url'] = grafana_dashboard_url if grafana_dashboard_url.present?

              if !active_alert && stored_alert["status"] != "stale" &&
                  STALE_DURATION.minute.ago > DateTime.parse(stored_alert["starts_at"])
                stored_alert["status"] = "stale"
                updated = true
              elsif active_alert && stored_alert["status"] != normalize_status(active_alert["status"]["state"])
                stored_alert["status"] = normalize_status(active_alert["status"]["state"])
                stored_alert["description"] = active_alert.dig("annotations", "description")
                updated = true
              end
            end
          end

          if updated
            topic.custom_fields[::DiscoursePrometheusAlertReceiver::ALERT_HISTORY_VERSION_CUSTOM_FIELD] = 2
            topic.save_custom_fields(true)
            klass = DiscoursePrometheusAlertReceiver

            if base_title = topic.custom_fields[klass::TOPIC_BASE_TITLE_CUSTOM_FIELD]
              title = generate_title(base_title, stored_alerts)
            else
              title = topic.custom_fields[klass::TOPIC_TITLE_CUSTOM_FIELD] || ''
            end

            raw = first_post_body(
              receiver: receiver,
              topic_body: topic.custom_fields[klass::TOPIC_BODY_CUSTOM_FIELD] || '',
              alert_history: stored_alerts,
              prev_topic_id: topic.custom_fields[klass::PREVIOUS_TOPIC_CUSTOM_FIELD]
            )

            revise_topic(
              topic: topic,
              title: title,
              raw: raw,
              datacenters: datacenters(stored_alerts),
              firing: stored_alerts.any? { |alert| is_firing?(alert["status"]) }
            )

            publish_alert_counts
          end
        end
      end
    end

    def publish_alert_counts
      MessageBus.publish("/alert-receiver",
        firing_alerts_count: Topic.firing_alerts.count,
        open_alerts_count: Topic.open_alerts.count
      )
    end
  end
end
