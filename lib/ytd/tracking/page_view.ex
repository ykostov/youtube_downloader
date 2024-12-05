defmodule Ytd.Tracking.PageView do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "page_views" do
    field :page, :string
    field :count, :integer, default: 0

    timestamps()
  end

  def changeset(page_view, attrs) do
    page_view
    |> cast(attrs, [:page, :count])
    |> validate_required([:page])
    |> unique_constraint(:page)
  end

  def increment(page_name) do
    result = Ytd.Repo.insert!(
      %__MODULE__{page: page_name, count: 1},
      on_conflict: [inc: [count: 1]],
      conflict_target: :page,
      returning: true
    )
    result.count
  end

  def get_count(page_name) do
    case Ytd.Repo.get_by(__MODULE__, page: page_name) do
      nil -> 0
      record -> record.count
    end
  end
end
