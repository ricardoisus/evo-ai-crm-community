# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::EvolutionService do
  let(:provider_config) do
    {
      'api_url' => 'https://evo.example.com',
      'admin_token' => 'test-token',
      'instance_name' => 'test-instance'
    }
  end
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:phone_number) { '+5511999999999' }
  let(:success_response) do
    instance_double(
      HTTParty::Response,
      success?: true,
      parsed_response: { 'key' => { 'id' => 'msg-id-123' } }
    )
  end

  describe '#fetch_contact_profile' do
    it 'reads pushName and profilePicUrl through /chat/findContacts' do
      response = instance_double(HTTParty::Response, success?: true,
                                 parsed_response: [{ 'pushName' => 'Ana Real', 'profilePicUrl' => 'https://pps.whatsapp.net/a.jpg' }])
      allow(HTTParty).to receive(:post).and_return(response)

      profile = service.fetch_contact_profile('+5511999999999')

      expect(profile).to eq(push_name: 'Ana Real', profile_picture_url: 'https://pps.whatsapp.net/a.jpg')
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo.example.com/chat/findContacts/test-instance')
        expect(JSON.parse(opts[:body])).to eq('where' => { 'remoteJid' => '5511999999999@s.whatsapp.net' })
      end
    end

    it 'returns nil on HTTP failure or empty result' do
      allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: false, code: 500))
      expect(service.fetch_contact_profile('5511999999999')).to be_nil
      allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: true, parsed_response: []))
      expect(service.fetch_contact_profile('5511999999999')).to be_nil
    end
  end

  describe '#fetch_profile_picture_url' do
    it 'POSTs the phone number to /chat/fetchProfilePictureUrl/{instance} and returns the URL' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'profilePictureUrl' => 'https://cdn.example.com/p.jpg' }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      url = service.fetch_profile_picture_url(phone_number)

      expect(url).to eq('https://cdn.example.com/p.jpg')
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo.example.com/chat/fetchProfilePictureUrl/test-instance')
        expect(JSON.parse(opts[:body])).to eq('number' => '5511999999999')
        expect(opts[:headers]['apikey']).to eq('test-token')
      end
    end

    it 'falls back to nested data.profilePictureUrl shape' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'data' => { 'profilePictureUrl' => 'https://cdn.example.com/nested.jpg' } }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to eq('https://cdn.example.com/nested.jpg')
    end

    it 'returns nil and logs when the upstream call fails' do
      response = instance_double(HTTParty::Response, success?: false, code: 502)
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil when 200 OK body carries an error key' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'error' => 'instance_disconnected', 'message' => 'instance not connected' }
      )
      allow(HTTParty).to receive(:post).and_return(response)
      allow(Rails.logger).to receive(:warn)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/200 OK with error body/)
    end

    it 'returns nil and rescues network errors' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'connection refused')

      expect { service.fetch_profile_picture_url(phone_number) }.not_to raise_error
      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil for blank input without hitting the network' do
      expect(HTTParty).not_to receive(:post)
      expect(service.fetch_profile_picture_url('')).to be_nil
      expect(service.fetch_profile_picture_url(nil)).to be_nil
    end
  end

  describe '#send_text_message (HTML to WhatsApp formatting)' do
    it 'converts bold HTML to WhatsApp bold' do
      message = instance_double('Message', content: '<strong>Hello</strong> World', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*Hello* World')
      end
    end

    it 'converts italic HTML to WhatsApp italic' do
      message = instance_double('Message', content: '<em>italic</em> text', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('_italic_ text')
      end
    end

    it 'converts code HTML to WhatsApp monospace' do
      message = instance_double('Message', content: 'use <code>method()</code> here', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('use `method()` here')
      end
    end

    it 'converts mixed formatting correctly' do
      message = instance_double('Message',
                                content: '<p><strong>Title</strong></p><p>Some <em>italic</em> and <code>code</code></p>',
                                content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('*Title*')
        expect(body['text']).to include('_italic_')
        expect(body['text']).to include('`code`')
        expect(body['text']).not_to match(/<[^>]+>/)
      end
    end

    it 'preserves plain text content unchanged' do
      message = instance_double('Message', content: 'Hello World', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('Hello World')
      end
    end

    it 'converts <br> tags to newlines' do
      message = instance_double('Message', content: 'Line 1<br>Line 2<br/>Line 3', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Line 1\nLine 2\nLine 3")
      end
    end

    it 'converts <p> blocks to double newlines' do
      message = instance_double('Message', content: '<p>Paragraph 1</p><p>Paragraph 2</p>', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Paragraph 1\n\nParagraph 2")
      end
    end

    it 'converts list items to dashes' do
      message = instance_double('Message',
                                content: '<ul><li>Item 1</li><li>Item 2</li></ul>',
                                content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('- Item 1')
        expect(body['text']).to include('- Item 2')
      end
    end

    it 'strips HTML-only content to empty string' do
      message = instance_double('Message', content: '<p></p>', content_attributes: {}, attachments: double(present?: false), content_type: 'text')

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('')
      end
    end

    it 'handles string message (template fallback)' do
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_text_message, phone_number, '<b>bold template</b>')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*bold template*')
      end
    end
  end

  describe '#send_media_message (caption formatting)' do
    let(:file_double) { instance_double('AttachmentFile', filename: double(to_s: 'photo.jpg'), attached?: false) }
    let(:attachment) do
      instance_double('Attachment', file_type: 'image', file: file_double,
                                    file_url: 'https://s3.example.com/photo.jpg')
    end

    it 'converts HTML in caption to WhatsApp formatting' do
      message = instance_double('Message', content: '<p>Check this <b>image</b></p>',
                                           content_attributes: {}, attachments: double(present?: true, first: attachment))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['caption']).to include('*image*')
        expect(body['caption']).not_to match(/<[^>]+>/)
      end
    end
  end

  describe '#send_media_message (mediatype mapping — EVO-1940)' do
    def attachment_double(file_type)
      file_double = instance_double('AttachmentFile', filename: double(to_s: "f.#{file_type}"), attached?: false)
      instance_double('Attachment', file_type: file_type, file: file_double,
                                    file_url: "https://s3.example.com/f.#{file_type}")
    end

    def send_attachment_of(file_type)
      message = instance_double('Message', content: 'caption',
                                           content_attributes: {}, attachments: double(present?: true, first: attachment_double(file_type)))
      allow(HTTParty).to receive(:post).and_return(success_response)
      service.send_message(phone_number, message)
    end

    it "maps a 'file' attachment (PDF/Word) to mediatype 'document'" do
      send_attachment_of('file')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('document')
      end
    end

    it "keeps 'image' as mediatype 'image' (no regression)" do
      send_attachment_of('image')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('image')
      end
    end

    it "keeps 'video' as mediatype 'video' (no regression)" do
      send_attachment_of('video')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        expect(JSON.parse(opts[:body])['mediatype']).to eq('video')
      end
    end

    it 'maps the full enum to canonical Evolution API media types' do
      expect(service.send(:map_file_type_to_evolution_media_type, 'file')).to eq('document')
      expect(service.send(:map_file_type_to_evolution_media_type, 'image')).to eq('image')
      expect(service.send(:map_file_type_to_evolution_media_type, 'audio')).to eq('audio')
      expect(service.send(:map_file_type_to_evolution_media_type, 'video')).to eq('video')
      expect(service.send(:map_file_type_to_evolution_media_type, 'fallback')).to eq('document')
    end

    it 'returns false when the provider rejects the media send (surfaces failure to caller)' do
      message = instance_double('Message', content: 'caption',
                                           content_attributes: {}, attachments: double(present?: true, first: attachment_double('file')))
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: false, code: 400, body: 'invalid mediatype')
      )

      expect(service.send_message(phone_number, message)).to be(false)
    end
  end

  describe 'quoted reply (in_reply_to)' do
    let(:parent) { instance_double('Message', source_id: 'WAID-PARENT') }
    let(:messages) { double('messages') }
    let(:conversation) { double('conversation', messages: messages) }
    let(:provider_config) do
      { 'api_url' => 'https://evo.example.com', 'admin_token' => 'test-token', 'instance_name' => 'CR Advogados' }
    end
    let(:requests) { [] }
    let(:success_response) do
      instance_double(HTTParty::Response, success?: true, code: 201, body: '{}',
                                          parsed_response: { 'key' => { 'id' => 'msg-id-123' } })
    end

    before do
      allow(messages).to receive(:find_by).with(id: 'parent-id').and_return(parent)
      allow(HTTParty).to receive(:post) do |url, opts|
        requests << [url, JSON.parse(opts[:body])]
        success_response
      end
    end

    def reply(file_type: nil, content_attributes: { 'in_reply_to' => 'parent-id' })
      file = instance_double('AttachmentFile', filename: double(to_s: 'f.bin'), attached?: false)
      attachment = file_type && instance_double('Attachment', file_type: file_type, file: file,
                                                              file_url: 'https://s3.example.com/f.bin')
      instance_double('Message', content: 'Resposta', content_type: 'text', conversation: conversation,
                                 content_attributes: content_attributes,
                                 attachments: double(present?: !attachment.nil?, first: attachment))
    end

    { nil => 'sendText', 'image' => 'sendMedia', 'video' => 'sendMedia', 'file' => 'sendMedia',
      'audio' => 'sendWhatsAppAudio' }.each do |file_type, endpoint|
      it "sends quoted.key.id on #{file_type || 'text'} and encodes the instance name" do
        service.send_message(phone_number, reply(file_type: file_type))

        url, body = requests.sole
        expect(url).to eq("https://evo.example.com/message/#{endpoint}/CR%20Advogados")
        expect(body['quoted']).to eq('key' => { 'id' => 'WAID-PARENT' })
      end
    end

    it 'keeps the quote on the base64 audio fallback' do
      file = instance_double('AttachmentFile', attached?: true, download: 'audio-bytes', blob: double)
      attachment = instance_double('Attachment', file_type: 'audio', file: file)
      message = instance_double('Message', content: nil, conversation: conversation,
                                           content_attributes: { 'in_reply_to' => 'parent-id' },
                                           attachments: double(present?: true, first: attachment))
      allow(BlobUrlOptions).to receive(:outbound_media_url).and_return('https://crm.example.com/a.ogg')
      allow(HTTParty).to receive(:post) do |_url, opts|
        requests << JSON.parse(opts[:body])
        requests.one? ? instance_double(HTTParty::Response, success?: false, code: 400, body: 'bad url') : success_response
      end

      service.send_message(phone_number, message)

      expect(requests.size).to eq(2)
      expect(requests.map { |body| body['quoted'] }).to all(eq('key' => { 'id' => 'WAID-PARENT' }))
    end

    it 'sends without quoted when the parent has no source_id' do
      allow(parent).to receive(:source_id).and_return(nil)

      service.send_message(phone_number, reply)

      expect(requests.sole.last).not_to have_key('quoted')
    end

    it 'sends without quoted when the parent is not in the conversation' do
      allow(messages).to receive(:find_by).with(id: 'parent-id').and_return(nil)

      service.send_message(phone_number, reply(file_type: 'image'))

      expect(requests.sole.last).not_to have_key('quoted')
    end

    it 'sends without quoted when the message is not a reply' do
      service.send_message(phone_number, reply(content_attributes: {}))

      expect(requests.sole.last).not_to have_key('quoted')
    end
  end
end
