defmodule Parser do
  use Platform.Parsing.Behaviour

  # Test hex payload: "51BBF1BD0228000000"
  def parse(<<header::8, meterid::integer-little-32, register_value::integer-little-32>>, _meta) do
  <<version::integer-little-2, medium::integer-little-3,qualifier::integer-little-3>> = <<header::8>>

    med = case medium do
      1 -> "temperature"
      2 -> "electricity"
      3 -> "gas"
      4 -> "heat"
      6 -> "hotwater"
      7 -> "water"
      _ -> "unknown"
    end

    %{
      qualifier: qualifier,
      meterid: meterid,
      medium: med,
      register: register_value/100,
    }
  end

end
