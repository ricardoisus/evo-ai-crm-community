Rails.application.config.after_initialize do
  VetorialAgent::GuardBoot.mark_ready!
end
