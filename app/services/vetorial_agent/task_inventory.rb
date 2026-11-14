# Input is a fresh, trusted docker service ps inventory, never a UI assertion.
class VetorialAgent::TaskInventory
  def self.verify!(services, digest)
    valid = digest.to_s.match?(/\A.+@sha256:[0-9a-f]{64}\z/) && services.is_a?(Hash) &&
      %w[crm sidekiq].all? do |service|
        tasks = services[service]
        tasks.is_a?(Array) && tasks.any? { |task| task['state'] == 'running' && task['image'] == digest } &&
          tasks.all? do |task|
            %w[shutdown complete failed rejected remove].include?(task['state']) || task['image'] == digest
          end
      end
    raise VetorialAgent::Configuration::Conflict unless valid
    true
  end
end
