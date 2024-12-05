defmodule Ytd.Tracking.PageView do
  @moduledoc """
  This module handles the tracking and persistence of page view counts.
  It provides functionality to increment counters and retrieve current counts
  for specific pages in the application using PostgreSQL for storage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "page_views" do
    field :page, :string
    field :count, :integer, default: 0

    timestamps()
  end

  @doc """
  Creates a changeset for page view data validation and constraints.

  ## Parameters
    * page_view - The current PageView struct
    * attrs - The attributes to be validated/changed

  ## Returns
    * A changeset containing the changes and validation results
  """
  def changeset(page_view, attrs) do
    page_view
    |> cast(attrs, [:page, :count])
    |> validate_required([:page])
    |> unique_constraint(:page)
  end

  @doc """
  Increments the view count for a specific page.
  Uses PostgreSQL's UPSERT feature to handle concurrent updates safely.

  ## Parameters
    * page_name - String representing the page identifier

  ## Returns
    * Integer representing the new count after increment
  """
  def increment(page_name) do
    result =
      Ytd.Repo.insert!(
        %__MODULE__{page: page_name, count: 1},
        on_conflict: [inc: [count: 1]],
        conflict_target: :page,
        returning: true
      )

    result.count
  end

  @doc """
  Retrieves the current view count for a specific page.

  ## Parameters
    * page_name - String representing the page identifier

  ## Returns
    * Integer representing the current count (0 if page not found)
  """
  def get_count(page_name) do
    case Ytd.Repo.get_by(__MODULE__, page: page_name) do
      nil -> 0
      record -> record.count
    end
  end
end
