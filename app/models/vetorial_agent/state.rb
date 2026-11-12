class VetorialAgent::State < ApplicationRecord
  self.table_name = 'vetorial_agent_states'
  belongs_to :conversation
end
