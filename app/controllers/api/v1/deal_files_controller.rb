# frozen_string_literal: true

class Api::V1::DealFilesController < Api::V1::BaseController
  include FileTypeHelper

  MAX_FILES = 10
  MAX_FILE_BYTES = 10.megabytes

  before_action :set_deal
  before_action :authorize_deal

  def index
    success_response(data: @deal.attachments.includes(file_attachment: :blob).map { |file| DealSerializer.attachment_data(file) })
  end

  def create
    files = normalized_files
    return validation_error('Send between 1 and 10 files') if files.empty? || files.length > MAX_FILES
    return validation_error('Each file must be at most 10 MB') if files.any? { |file| file.size > MAX_FILE_BYTES }
    if files.any? { |file| !safe_content_type?(file.content_type) }
      return validation_error('One or more files have an unsupported type')
    end

    created = files.map { |file| attach_file(file) }
    @deal.record_history!(
      'files_attached', metadata: { attachment_ids: created.map(&:id), names: created.map(&:fallback_title) }
    )
    success_response(
      data: created.map { |file| DealSerializer.attachment_data(file) },
      message: 'Files uploaded successfully', status: :created
    )
  end

  def destroy
    attachment = @deal.attachments.find(params[:id])
    metadata = { attachment_id: attachment.id, name: attachment.file.filename.to_s }
    attachment.destroy!
    @deal.record_history!('file_removed', metadata: metadata)
    success_response(data: { id: params[:id] }, message: 'File removed successfully')
  end

  private

  def set_deal
    @deal = PipelineItem.find(params[:deal_id])
  end

  def authorize_deal
    authorize @deal.pipeline, action_name == 'index' ? :view? : :update? unless service_authenticated?
  end

  def normalized_files
    Array(params[:files].presence || params[:attachments]).compact
  end

  def safe_content_type?(content_type)
    content_type.to_s.start_with?('image/', 'audio/', 'video/') || Attachment::ACCEPTABLE_FILE_TYPES.include?(content_type)
  end

  def attach_file(file)
    attachment = @deal.attachments.build(file_type: file_type_for(file.content_type), fallback_title: file.original_filename)
    attachment.file.attach(io: file, filename: file.original_filename, content_type: file.content_type)
    attachment.save!
    attachment
  end

  def file_type_for(content_type)
    return :image if content_type.to_s.start_with?('image/')
    return :audio if content_type.to_s.start_with?('audio/')
    return :video if content_type.to_s.start_with?('video/')

    :file
  end

  def validation_error(message)
    error_response(ApiErrorCodes::VALIDATION_ERROR, message, status: :unprocessable_entity)
  end
end
