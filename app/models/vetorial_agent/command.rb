class VetorialAgent::Command < ApplicationRecord
  self.table_name = 'vetorial_agent_commands'
  belongs_to :conversation
end
