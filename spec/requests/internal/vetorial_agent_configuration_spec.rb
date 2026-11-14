require 'rails_helper'

RSpec.describe 'Internal configuration authentication', type: :request do
  let(:path) { '/internal/vetorial_agent/config/00000000-0000-4000-8000-000000000001' }
  it 'rejects unauthenticated snapshots before lookup' do
    get path
    expect(response.status).to eq(401)
  end
end
