class VetorialAgent::TelemetryEvent < ApplicationRecord
  self.table_name = 'vetorial_agent_telemetry_events'
  belongs_to :deployment, class_name: 'VetorialAgent::Deployment'
end
