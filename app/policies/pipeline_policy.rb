class PipelinePolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    def resolve
      # Return all pipelines accessible to the user
      scope.all
    end
  end

  def index?
    # Administrators or users with pipelines.read permission can list pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end

  def show?
    return false unless LeadAutomations::CraAccess.allowed?(record, @user)
    # Administrators or users with pipelines.read permission can view pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end

  def view?
    # Alias for show? - used by some controllers
    show?
  end

  def create?
    # Administrators or users with pipelines.create permission can create pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.create')
  end

  def update?
    return false unless LeadAutomations::CraAccess.allowed?(record, @user)
    # Administrators or users with pipelines.update permission can update pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.update')
  end

  def destroy?
    # Administrators or users with pipelines.delete permission can delete pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.delete')
  end

  def archive?
    # Administrators or users with pipelines.update permission can archive pipelines
    @user&.administrator? || @user&.has_permission?('pipelines.update')
  end

  def stats?
    # Administrators or users with pipelines.read permission can view pipeline statistics
    @user&.administrator? || @user&.has_permission?('pipelines.read')
  end
end
