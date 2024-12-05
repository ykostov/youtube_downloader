defmodule Ytd.Repo.Migrations.CreatePageViews do
  use Ecto.Migration

  def change do
    create table(:page_views) do
      add :page, :string
      add :count, :integer, default: 0

      timestamps()
    end

    create unique_index(:page_views, [:page])
  end
end
