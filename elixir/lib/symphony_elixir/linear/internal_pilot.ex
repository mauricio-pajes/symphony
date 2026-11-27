defmodule SymphonyElixir.Linear.InternalPilot do
  @moduledoc """
  Reads a scoped Linear pilot issue and projects its workflow milestones.
  All queries carry the frozen host configuration. Mutations are never retried.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue

  @issue_fields """
    issues(filter: {id: {eq: $id}, project: {slugId: {eq: $project}}}, first: 1) {
      nodes { id identifier title description url archivedAt state { id name } team { id } }
    }
    workflowState(id: $review) { id name team { id } }
  """
  @read """
  query SymphonyPilotIssue($id: ID!, $project: String!, $review: String!) {
    #{@issue_fields}
  }
  """
  @read_with_progress """
  query SymphonyPilotIssue($id: ID!, $project: String!, $review: String!, $progress: String!) {
    #{@issue_fields}
    progress: workflowState(id: $progress) { id name type team { id } }
  }
  """
  @move_to_progress """
  mutation SymphonyPilotInProgress($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId}) {
      success
      issue { id state { id name } }
    }
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

  @move_with_evidence """
  mutation SymphonyPilotHumanReview($id: String!, $stateId: String!, $description: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId, description: $description}) {
      success
      issue { id state { id name } }
    }
  }
  """

  @type item :: %{issue: Issue.t(), state_id: String.t(), team_id: String.t()}
  @type scope :: %{issue_id: String.t(), review_id: String.t(), progress_id: String.t() | nil, tracker: map()}

  @spec read(scope()) :: {:ok, item()} | {:error, term()}
  def read(%{issue_id: id, review_id: review, progress_id: progress, tracker: tracker}) do
    vars = %{id: id, project: tracker.project_slug, review: review}
    {query, vars} = if progress, do: {@read_with_progress, Map.put(vars, :progress, progress)}, else: {@read, vars}

    with {:ok, data} <- graphql(tracker, query, vars),
         %{"id" => ^review, "name" => "Human Review", "team" => %{"id" => team}} <- data["workflowState"],
         true <- valid_progress?(progress, team, data["progress"]),
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
      _unexpected -> {:error, :pilot_issue_or_workflow_state_out_of_scope}
    end
  end

  defp valid_progress?(nil, _team, _state), do: true

  defp valid_progress?(id, team, state) do
    match?(%{"id" => ^id, "name" => "In Progress", "type" => "started", "team" => %{"id" => ^team}}, state)
  end

  @spec move_to_progress(scope()) :: :ok | {:error, term()}
  def move_to_progress(%{issue_id: id, progress_id: progress, tracker: tracker}) do
    move(tracker, {@move_to_progress, %{id: id, stateId: progress}}, "In Progress", :pilot_start_transition_unconfirmed)
  end

  @spec move_to_review(scope(), String.t() | nil) :: :ok | {:error, term()}
  def move_to_review(%{issue_id: id, review_id: review, tracker: tracker}, description) do
    move(tracker, update_input(id, review, description), "Human Review", :pilot_review_transition_unconfirmed)
  end

  defp move(tracker, {query, %{id: id, stateId: destination} = vars}, state, unconfirmed) do
    with {:ok, data} <- graphql(tracker, query, vars),
         %{"success" => true, "issue" => %{"id" => ^id, "state" => issue_state}} <- data["issueUpdate"],
         %{"id" => ^destination, "name" => ^state} <- issue_state do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, unconfirmed}
    end
  end

  defp update_input(id, review, nil), do: {@move, %{id: id, stateId: review}}

  defp update_input(id, review, description),
    do: {@move_with_evidence, %{id: id, stateId: review, description: description}}

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
