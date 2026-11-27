defmodule SymphonyElixir.Linear.InternalPilot do
  @moduledoc """
  Reads the one configured Linear test issue and projects its review milestone.
  All queries carry the frozen host configuration. Mutations are never retried.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue

  @read """
  query SymphonyPilotIssue($id: ID!, $project: String!, $review: String!) {
    issues(filter: {id: {eq: $id}, project: {slugId: {eq: $project}}}, first: 1) {
      nodes { id identifier title description url archivedAt state { id name } team { id } }
    }
    workflowState(id: $review) { id name team { id } }
  }
  """
  @move """
  mutation SymphonyPilotHumanReview($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId}) {
      success
      issue { id state { id name } }
    }
  }
  """

  @type item :: %{issue: Issue.t(), state_id: String.t(), team_id: String.t()}
  @type scope :: %{issue_id: String.t(), review_id: String.t(), tracker: map()}

  @spec read(scope()) :: {:ok, item()} | {:error, term()}
  def read(%{issue_id: id, review_id: review, tracker: tracker}) do
    vars = %{id: id, project: tracker.project_slug, review: review}

    with {:ok, data} <- graphql(tracker, @read, vars),
         %{"id" => ^review, "name" => "Human Review", "team" => %{"id" => team}} <- data["workflowState"],
         [%{"id" => ^id, "team" => %{"id" => ^team}, "archivedAt" => nil} = node] <- get_in(data, ["issues", "nodes"]),
         %{"id" => state_id, "name" => state} when is_binary(state_id) and is_binary(state) <- node["state"],
         %{"identifier" => identifier, "title" => title} when is_binary(identifier) and is_binary(title) <- node do
      issue = %Issue{
        id: id,
        identifier: identifier,
        title: title,
        description: node["description"],
        state: state,
        url: node["url"]
      }

      {:ok, %{issue: issue, state_id: state_id, team_id: team}}
    else
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :pilot_issue_or_review_state_out_of_scope}
    end
  end

  @spec move_to_review(scope()) :: :ok | {:error, term()}
  def move_to_review(%{issue_id: id, review_id: review, tracker: tracker}) do
    with {:ok, data} <- graphql(tracker, @move, %{id: id, stateId: review}),
         %{"success" => true, "issue" => %{"id" => ^id, "state" => %{"id" => ^review, "name" => "Human Review"}}} <- data["issueUpdate"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :pilot_review_transition_unconfirmed}
    end
  end

  defp graphql(tracker, query, vars) do
    request = fn payload, headers ->
      Req.post(tracker.endpoint,
        json: payload,
        headers: headers,
        retry: false,
        redirect: false,
        connect_options: [timeout: 3000],
        receive_timeout: 3000
      )
    end

    with {:ok, response} <- Client.graphql(query, vars, tracker_settings: tracker, request_fun: request),
         %{"data" => data} when is_map(data) <- response,
         [] <- Map.get(response, "errors", []) do
      {:ok, data}
    else
      _error -> {:error, :pilot_linear_request_failed}
    end
  end
end
