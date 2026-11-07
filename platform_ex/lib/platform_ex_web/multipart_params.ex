defmodule PlatformExWeb.MultipartParams do
  @moduledoc """
  multipart の部品列を params に組み立てる（Plug.Parsers の
  :multipart_to_params に渡す関数）。

  Plug 標準の組み立て（Plug.Conn.Query 方式）は、同じ名前のファイル部品が
  複数あると最後の1つしか残さない。"files" を繰り返し追加する FormData の
  形（FastAPI が受け付ける形）を保つため、ここで組み立て直す：

  - "files" は出現順のリストのまま
  - ファイルだけが集まった名前（cover を除く）もリストのまま
  - それ以外は最後の値（Starlette のフォーム解決と同じ）
  """

  alias Plug.Upload

  def to_params(parts, conn) do
    grouped =
      parts
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn
        {nil, _headers, _body}, acc ->
          acc

        {name, _headers, body}, acc ->
          Map.update(acc, name, [body], &(&1 ++ [body]))
      end)

    params =
      Map.new(grouped, fn
        {"files", values} ->
          {"files", values}

        {name, values} ->
          if name != "cover" and Enum.all?(values, &match?(%Upload{}, &1)) do
            {name, values}
          else
            {name, List.last(values)}
          end
      end)

    {:ok, params, conn}
  end
end
