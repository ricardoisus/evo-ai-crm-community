class VetorialAgent::Event < ApplicationRecord
  self.table_name = 'vetorial_agent_events'
  belongs_to :conversation
  after_create_commit -> { VetorialAgent::DispatchJob.perform_later }
end
