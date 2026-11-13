# Called only by the guarded code boot, never by import, migration or binding.
class VetorialAgent::GuardBoot
  def self.mark_ready!
    return unless VetorialAgent::Deployment.table_exists?
    return unless VetorialAgent::Deployment.column_names.include?('guard_ready')

    VetorialAgent::Deployment.where(guard_ready: false).update_all(guard_ready: true)
  end
end
