defmodule YomimaExTest do
  use ExUnit.Case
  doctest YomimaEx

  test "greets the world" do
    assert YomimaEx.hello() == :world
  end
end
