# SPDX-License-Identifier: MPL-2.0

defmodule BurbleWeb.ErrorJSON do
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
