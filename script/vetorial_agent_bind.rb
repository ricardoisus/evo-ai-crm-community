# bundle exec rails runner script/vetorial_agent_bind.rb DEPLOYMENT_ID IMAGE@sha256:DIGEST < inventory.json
# Fresh full inventory: crm/sidekiq arrays of {"state":"running", "image":"...@sha256:..."}.
# Never filter by desired-state: old shutdown tasks can still be running.
deployment = VetorialAgent::Deployment.find(ARGV.fetch(0))
VetorialAgent::Binding.attach!(deployment, digest: ARGV.fetch(1), inventory: -> { JSON.parse($stdin.read) })
puts 'Vínculo gerenciado verificado.'
