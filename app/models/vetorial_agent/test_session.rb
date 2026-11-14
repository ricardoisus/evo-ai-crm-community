# Authorization and synthetic transcript only. Money belongs to the runtime ledger.
class VetorialAgent::TestSession < ApplicationRecord
  self.table_name = 'vetorial_agent_test_sessions'
  belongs_to :profile, class_name: 'VetorialAgent::Profile'
  belongs_to :owner, class_name: 'User'
  belongs_to :revision, class_name: 'VetorialAgent::Revision'
end
