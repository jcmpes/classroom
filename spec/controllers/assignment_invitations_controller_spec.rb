# frozen_string_literal: true

require "rails_helper"

RSpec.describe AssignmentInvitationsController, type: :controller do
  let(:organization)  { classroom_org     }
  let(:user)          { classroom_student }
  let(:config_branch) { ClassroomConfig::CONFIG_BRANCH }

  let(:invitation) { create(:assignment_invitation, organization: organization) }

  let(:unconfigured_repo) { stub_repository("template") }
  let(:configured_repo) { stub_repository("configured-repo") }

  describe "GET #show", :vcr do
    context "unauthenticated request" do
      it "redirects the new user to sign in with GitHub" do
        get :show, params: { id: invitation.key }
        expect(response).to redirect_to(login_path)
      end
    end

    context "authenticated request" do
      before(:each) do
        sign_in_as(user)
      end

      context "no roster" do
        it "will bring you to the page" do
          get :show, params: { id: invitation.key }
          expect(response).to have_http_status(:success)
          expect(response).to render_template("assignment_invitations/show")
        end
      end

      context "with a roster" do
        before do
          organization.roster = create(:roster)
          organization.save
        end

        context "with no ignore param" do
          context "when user is on the roster" do
            before do
              RosterEntry.create(roster: organization.roster, user: user, identifier: "a@b.c")
            end

            it "will bring you to the show page" do
              get :show, params: { id: invitation.key }
              expect(response).to render_template("assignment_invitations/show")
            end
          end

          context "when user is not on the roster" do
            it "will bring you to the join_roster page" do
              get :show, params: { id: invitation.key }
              expect(response).to render_template("assignment_invitations/join_roster")
            end
          end
        end

        context "with ignore param" do
          it "will bring you to the show page" do
            get :show, params: { id: invitation.key, roster: "ignore" }
            expect(response).to have_http_status(:success)
            expect(response).to render_template("assignment_invitations/show")
          end
        end
      end
    end
  end

  describe "PATCH #accept", :vcr do
    let(:result) do
      assignment_repo = create(:assignment_repo, assignment: invitation.assignment, user: user)
      AssignmentRepo::Creator::Result.success(assignment_repo)
    end

    before do
      request.env["HTTP_REFERER"] = "http://classroomtest.com/assignment-invitations/#{invitation.key}"
      sign_in_as(user)
    end

    it "redeems the users invitation" do
      allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for).with(user).and_return(result)

      patch :accept, params: { id: invitation.key }
      expect(user.assignment_repos.count).to eql(1)
    end

    it "sends an event to statsd" do
      expect(GitHubClassroom.statsd).to receive(:increment).with("exercise_invitation.accept")

      allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for).with(user).and_return(result)

      patch :accept, params: { id: invitation.key }
    end

    context "with import resiliency enabled" do
      before do
        GitHubClassroom.flipper[:import_resiliency].enable
      end

      after do
        GitHubClassroom.flipper[:import_resiliency].disable
      end

      it "sends an event to statsd" do
        expect(GitHubClassroom.statsd).to receive(:increment).with("v2_exercise_invitation.accept")

        allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for)
          .with(user, import_resiliency: true)
          .and_return(result)

        patch :accept, params: { id: invitation.key }
      end

      it "redirects to success when AssignmentRepo already exists" do
        invitation.status(user).completed!
        allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for)
          .with(user, import_resiliency: true)
          .and_return(result)

        patch :accept, params: { id: invitation.key }
        expect(response).to redirect_to(success_assignment_invitation_url(invitation))
      end

      it "redirects to setup when AssignmentRepo already exists but isn't completed" do
        invitation.status(user).creating_repo!
        allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for)
          .with(user, import_resiliency: true)
          .and_return(result)

        patch :accept, params: { id: invitation.key }
        expect(response).to redirect_to(setupv2_assignment_invitation_url(invitation))
      end

      it "redirects to setupv2 when AssignmentRepo doesn't already exist" do
        allow_any_instance_of(AssignmentInvitation).to receive(:redeem_for)
          .with(user, import_resiliency: true)
          .and_return(AssignmentRepo::Creator::Result.pending)

        patch :accept, params: { id: invitation.key }
        expect(response).to redirect_to(setupv2_assignment_invitation_url(invitation))
      end
    end
  end

  describe "POST #create_repo", :vcr do
    before do
      sign_in_as(user)
    end

    it "404 when feature is off" do
      post :create_repo, params: { id: invitation.key }
      expect(response.status).to eq(404)
    end

    context "with import resiliency enabled" do
      before do
        GitHubClassroom.flipper[:import_resiliency].enable
      end

      after do
        GitHubClassroom.flipper[:import_resiliency].disable
      end

      context "when invitation status is accepted" do
        before do
          invitation.status(user).accepted!
        end

        it "enqueues a CreateRepositoryJob" do
          assert_enqueued_jobs 1, only: AssignmentRepo::CreateGitHubRepositoryJob do
            post :create_repo, params: { id: invitation.key }
          end
        end

        it "says a job was succesfully kicked off" do
          post :create_repo, params: { id: invitation.key }
          expect(response.body)
            .to eq({
              job_started: true,
              status: "waiting"
            }.to_json)
        end
      end

      context "when invitation status is errored" do
        before do
          invitation.status(user).errored_creating_repo!
        end

        it "deletes an assignment repo if one already exists and is empty" do
          Octokit.reset!
          client = oauth_client

          empty_github_repository = GitHubRepository.new(client, 141_328_892)
          AssignmentRepo.create(assignment: invitation.assignment, github_repo_id: 8485, user: user)
          allow_any_instance_of(AssignmentRepo).to receive(:github_repository).and_return(empty_github_repository)
          expect_any_instance_of(AssignmentRepo).to receive(:destroy)
          post :create_repo, params: { id: invitation.key }
        end

        it "doesn't delete an assignment repo when one already exists and is not empty" do
          Octokit.reset!
          client = oauth_client

          github_repository = GitHubRepository.new(client, 35_079_964)
          AssignmentRepo.create(assignment: invitation.assignment, github_repo_id: 8485, user: user)
          allow_any_instance_of(AssignmentRepo).to receive(:github_repository).and_return(github_repository)
          expect_any_instance_of(AssignmentRepo).not_to receive(:destroy)
          post :create_repo, params: { id: invitation.key }
        end

        it "enqueues a CreateRepositoryJob" do
          assert_enqueued_jobs 1, only: AssignmentRepo::CreateGitHubRepositoryJob do
            post :create_repo, params: { id: invitation.key }
          end
        end

        it "says a job was succesfully kicked off" do
          post :create_repo, params: { id: invitation.key }
          expect(response.body)
            .to eq({
              job_started: true,
              status: "waiting"
            }.to_json)
        end

        it "reports an error was retried" do
          expect(GitHubClassroom.statsd).to receive(:increment).with("v2_exercise_repo.retry")
          post :create_repo, params: { id: invitation.key }
        end
      end

      context "when invitation status is anything else" do
        before do
          invitation.status(user).unaccepted!
        end

        it "does not enqueue a CreateRepositoryJob" do
          assert_enqueued_jobs 0, only: AssignmentRepo::CreateGitHubRepositoryJob do
            post :create_repo, params: { id: invitation.key }
          end
        end

        it "says a job was unsuccesfully kicked off" do
          post :create_repo, params: { id: invitation.key }
          expect(response.body)
            .to eq({
              job_started: false,
              status: "unaccepted"
            }.to_json)
        end
      end
    end
  end

  describe "GET #setupv2", :vcr do
    before(:each) do
      sign_in_as(user)
    end

    it "404s when feature is off" do
      get :setupv2, params: { id: invitation.key }
      expect(response.status).to eq(404)
    end

    context "with import resiliency enabled" do
      before do
        GitHubClassroom.flipper[:import_resiliency].enable
      end

      after do
        GitHubClassroom.flipper[:import_resiliency].disable
      end

      it "will bring you to the page" do
        get :setupv2, params: { id: invitation.key }
        expect(response).to have_http_status(:success)
        expect(response).to render_template("assignment_invitations/setupv2")
      end
    end
  end

  describe "GET #progress", :vcr do
    before do
      sign_in_as(user)
    end

    it "404 when feature is off" do
      post :create_repo, params: { id: invitation.key }
      expect(response.status).to eq(404)
    end

    context "with import resiliency enabled" do
      before do
        GitHubClassroom.flipper[:import_resiliency].enable
      end

      after do
        GitHubClassroom.flipper[:import_resiliency].disable
      end

      it "returns the correct status" do
        get :progress, params: { id: invitation.key }
        expect(response.body).to eq({ status: invitation.status(user).status }.to_json)
      end

      it "returns the correct status when status is changed" do
        invitation.status(user).errored_creating_repo!
        get :progress, params: { id: invitation.key }
        expect(response.body).to eq({ status: invitation.status(user).status }.to_json)
      end
    end
  end

  describe "GET #success" do
    let(:assignment) do
      create(:assignment, title: "Learn Clojure", starter_code_repo_id: 1_062_897, organization: organization)
    end

    let(:invitation) { create(:assignment_invitation, assignment: assignment) }

    before(:each) do
      sign_in_as(user)
      result = AssignmentRepo::Creator.perform(assignment: assignment, user: user)
      @assignment_repo = result.assignment_repo
    end

    after(:each) do
      AssignmentRepo.destroy_all
    end

    context "github repository deleted after accepting a invitation successfully", :vcr do
      before do
        organization.github_client.delete_repository(@assignment_repo.github_repo_id)
        get :success, params: { id: invitation.key }
      end

      it "deletes the old assignment repo" do
        expect { @assignment_repo.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "creates a new assignment repo for the student" do
        expect(AssignmentRepo.last.id).not_to eq(@assignment_repo.id)
      end
    end

    describe "import resiliency enabled", :vcr do
      before do
        GitHubClassroom.flipper[:import_resiliency].enable
      end

      after do
        GitHubClassroom.flipper[:import_resiliency].disable
      end

      it "redirects to setupv2 when current_submission" do
        expect_any_instance_of(GitHubRepository)
          .to receive(:present?)
          .with(headers: GitHub::APIHeaders.no_cache_no_store)
          .and_return(false)
        get :success, params: { id: invitation.key }
        expect(response).to redirect_to(setupv2_assignment_invitation_url(invitation))
      end
    end
  end

  describe "PATCH #join_roster", :vcr do
    before do
      organization.roster = create(:roster)
      organization.save
    end

    context "unauthenticated request" do
      it "redirects the new user to sign in with GitHub" do
        patch :join_roster, params: { id: invitation.key }
        expect(response).to redirect_to(login_path)
      end
    end

    context "authenticated request" do
      before(:each) do
        sign_in_as(user)
      end

      context "with invalid roster entry id" do
        before do
          patch :join_roster, params: { id: invitation.key, roster_entry_id: "not_an_id" }
        end

        it "renders join_roster view" do
          expect(response).to render_template("assignment_invitations/join_roster")
        end

        it "shows flash message" do
          expect(flash[:error]).to be_present
        end
      end

      context "with a valid roster entry id" do
        before do
          entry = organization.roster.roster_entries.first
          patch :join_roster, params: { id: invitation.key, roster_entry_id: entry.id }
        end

        it "adds the user to the roster entry" do
          expect(RosterEntry.find_by(user: user, roster: organization.roster)).to be_present
        end

        it "renders show" do
          expect(response).to redirect_to(assignment_invitation_url(invitation))
        end
      end
    end
  end
end
