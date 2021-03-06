defmodule Phoenix.LiveViewTest.DOM do
  @moduledoc false

  @phx_component "data-phx-component"
  @static :s
  @dynamics :d
  @components :c

  def ensure_loaded! do
    unless Code.ensure_loaded?(Floki) do
      raise """
      Phoenix LiveView requires Floki as a test dependency.
      Please add to your mix.exs:

      {:floki, ">= 0.0.0", only: :test}
      """
    end
  end

  def parse(html) do
    {:ok, parsed} = Floki.parse_document(html)
    parsed
  end

  def all(html_tree, selector), do: Floki.find(html_tree, selector)

  def maybe_one(html_tree, selector, type \\ :selector) do
    case all(html_tree, selector) do
      [node] ->
        {:ok, node}

      [] ->
        {:error, :none,
         "expected #{type} #{inspect(selector)} to return a single element, but got none"}

      many ->
        {:error, :many,
         "expected #{type} #{inspect(selector)} to return a single element, " <>
           "but got #{length(many)}"}
    end
  end

  def all_attributes(html_tree, name), do: Floki.attribute(html_tree, name)

  def all_values({_, attributes, _}) do
    for {attr, value} <- attributes, key = value_key(attr), do: {key, value}, into: %{}
  end

  defp value_key("phx-value-" <> key), do: key
  defp value_key("value"), do: "value"
  defp value_key(_), do: nil

  def attribute({_tag, attrs, _children}, key) do
    case List.keyfind(attrs, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  def to_html(html_tree), do: Floki.raw_html(html_tree)

  def to_text(html_tree), do: Floki.text(html_tree)

  def by_id!(html_tree, id) do
    case maybe_one(html_tree, "#" <> id) do
      {:ok, node} -> node
      {:error, _, message} -> raise message
    end
  end

  def child_nodes({_, _, nodes}), do: nodes

  def inner_html!(html, id), do: html |> by_id!(id) |> child_nodes()

  def component_id(html_tree), do: Floki.attribute(html_tree, @phx_component) |> List.first()

  def find_static_views(html) do
    html
    |> all("[data-phx-static]")
    |> Enum.into(%{}, fn node ->
      {attribute(node, "id"), attribute(node, "data-phx-static")}
    end)
  end

  def find_live_views(html) do
    html
    |> all("[data-phx-session]")
    |> Enum.reduce([], fn node, acc ->
      id = attribute(node, "id")
      static = attribute(node, "data-phx-static")
      session = attribute(node, "data-phx-session")
      main = attribute(node, "data-phx-main")

      static = if static in [nil, ""], do: nil, else: static
      found = {id, session, static}

      if main == "true" do
        [found | acc]
      else
        acc ++ [found]
      end
    end)
  end

  def deep_merge(target, source) do
    Map.merge(target, source, fn
      _, %{} = target, %{} = source -> deep_merge(target, source)
      _, _target, source -> source
    end)
  end

  # Diff rendering

  def render_diff(rendered) do
    render_diff(rendered, Map.get(rendered, @components, %{}))
  end

  def render_diff(rendered, components) do
    rendered
    |> to_output_buffer(components, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> parse()
    |> List.wrap()
  end

  # for comprehension
  defp to_output_buffer(%{@dynamics => for_dynamics, @static => statics}, components, acc) do
    Enum.reduce(for_dynamics, acc, fn dynamics, acc ->
      dynamics
      |> Enum.with_index()
      |> Enum.into(%{@static => statics}, fn {val, key} -> {key, val} end)
      |> to_output_buffer(components, acc)
    end)
  end

  defp to_output_buffer(%{@static => [head | tail]} = rendered, components, acc) do
    tail
    |> Enum.with_index(0)
    |> Enum.reduce([head | acc], fn {static, index}, acc ->
      [static | dynamic_to_buffer(rendered[index], components, acc)]
    end)
  end

  defp dynamic_to_buffer(%{} = rendered, components, acc) do
    to_output_buffer(rendered, components, []) ++ acc
  end

  defp dynamic_to_buffer(str, _components, acc) when is_binary(str), do: [str | acc]

  defp dynamic_to_buffer(cid, components, acc) when is_integer(cid) do
    html_with_cids =
      components
      |> Map.fetch!(cid)
      |> render_diff(components)
      |> Enum.map(walk_fun(&inject_cid_attr(&1, cid)))
      |> to_html()

    [html_with_cids | acc]
  end

  defp inject_cid_attr({tag, attrs, children}, cid) do
    {tag, attrs ++ [{@phx_component, to_string(cid)}], children}
  end

  # Patching

  def patch_id(id, html, inner_html) do
    cids_before = inner_component_ids(id, html)

    phx_update_tree =
      walk(inner_html, fn node ->
        apply_phx_update(attribute(node, "phx-update"), html, node)
      end)

    new_html =
      walk(html, fn {tag, attrs, children} = node ->
        if attribute(node, "id") == id do
          {tag, attrs, phx_update_tree}
        else
          {tag, attrs, children}
        end
      end)

    cids_after = inner_component_ids(id, new_html)
    deleted_cids = for cid <- cids_before -- cids_after, do: String.to_integer(cid)
    {new_html, deleted_cids}
  end

  defp inner_component_ids(id, html) do
    html
    |> by_id!(id)
    |> all("[#{@phx_component}]")
    |> all_attributes(@phx_component)
  end

  defp apply_phx_update(type, html, {tag, attrs, appended_children} = node)
       when type in ["append", "prepend"] do
    id = attribute(node, "id")
    verify_phx_update_id!(type, id)
    children_before = apply_phx_update_children(html, id)
    existing_ids = apply_phx_update_children_id(type, children_before)
    new_ids = apply_phx_update_children_id(type, appended_children)
    content_changed? = new_ids != existing_ids

    dup_ids =
      if content_changed? && new_ids do
        Enum.filter(new_ids, fn id -> id in existing_ids end)
      else
        []
      end

    {updated_existing_children, updated_appended} =
      Enum.reduce(dup_ids, {children_before, appended_children}, fn dup_id, {before, appended} ->
        patched_before =
          walk(before, fn {tag, attrs, _} = node ->
            cond do
              attribute(node, "id") == dup_id -> {tag, attrs, inner_html!(appended, dup_id)}
              true -> node
            end
          end)

        {patched_before, Floki.filter_out(appended, "##{dup_id}")}
      end)

    cond do
      content_changed? && type == "append" ->
        {tag, attrs, updated_existing_children ++ updated_appended}

      content_changed? && type == "prepend" ->
        {tag, attrs, updated_appended ++ updated_existing_children}

      !content_changed? ->
        {tag, attrs, updated_appended}
    end
  end

  defp apply_phx_update("ignore", _state, node) do
    verify_phx_update_id!("ignore", attribute(node, "id"))
    node
  end

  defp apply_phx_update(type, _state, node) when type in [nil, "replace"] do
    node
  end

  defp apply_phx_update(other, _state, _node) do
    raise ArgumentError,
          "invalid phx-update value #{inspect(other)}, " <>
            "expected one of \"replace\", \"append\", \"prepend\", \"ignore\""
  end

  defp verify_phx_update_id!(type, id) when id in ["", nil] do
    raise ArgumentError,
          "setting phx-update to #{inspect(type)} requires setting an ID on the container"
  end

  defp verify_phx_update_id!(_type, _id) do
    :ok
  end

  defp apply_phx_update_children(html, id) do
    case by_id(html, id) do
      {_, _, children_before} -> children_before
      nil -> []
    end
  end

  defp apply_phx_update_children_id(type, children) do
    for child <- children do
      attribute(child, "id") ||
        raise ArgumentError,
              "setting phx-update to #{inspect(type)} requires setting an ID on each child. " <>
                "No ID was found on:\n\n#{to_html(child)}"
    end
  end

  ## Helpers

  defp walk(html_tree, fun) when is_function(fun, 1) do
    Floki.traverse_and_update(html_tree, walk_fun(fun))
  end

  defp walk_fun(fun) when is_function(fun, 1) do
    fn
      {:pi, _, _} = xml -> xml
      {:comment, _children} = comment -> comment
      {:doctype, _, _, _} = doctype -> doctype
      {_tag, _attrs, _children} = node -> fun.(node)
    end
  end

  defp by_id(html_tree, id) do
    html_tree |> Floki.find("##{id}") |> List.first()
  end
end
