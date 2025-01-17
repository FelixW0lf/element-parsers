defmodule Parser do

  use Platform.Parsing.Behaviour
  require Logger

  # Parser for Elvaco CMi4110 devices according to "CMi4110 User's Manual English.pdf"
  #
  # This Parser will support multiple Elvaco devices like CMi4110 and CMi4140 and other that are sending MBus payloads
  #
  # CMi4110 is a cost-effective MCM, which is mounted in a Landis+Gyr UH50 meter to, in a very energy-efficient way, deliver high-precision meter data using the LoRaWAN network.
  #
  # Changelog:
  #   2018-03-21 [jb]: initial version
  #   2019-07-02 [gw]: update according to v1.3 of documentation by adding precise error messages.
  #   2019-07-08 [gw]: Use LibWmbus library to parse the dibs. Changes most of the field names previously defined.
  #   2019-09-06 [jb]: Added parsing catchall for unknown payloads.
  #   2020-06-29 [jb]: Added filter_unknown_data() filtering :unknown Mbus data.
  #   2020-07-08 [jb]: Added all error flags in build_error_string()
  #   2020-11-24 [jb]: Added do_extend_reading and OBIS "6-0:1.0.0" to data.
  #   2021-04-15 [jb]: Removing value not parseable by LibWmbus

  defp do_extend_reading(%{energy: energy, energy_unit: "kWh"} = reading) do
    Map.merge(reading, %{
      :"6-0:1.0.0" => energy,
    })
  end
  # Use this function to add more fields to readings for integration purposes. By default doing nothing.
  defp do_extend_reading(fields), do: fields

  # When using payload style 0, the payload is made up of DIBs on M-Bus format, excluding M-Bus header.
  def parse(<<type::8, dibs_binary::binary,>>, _meta) do

    # Remove part that can CURRENTLY not be parsed by LibWmbus.Dib
    dibs_size_before = byte_size(dibs_binary)-4
    dibs_binary = case dibs_binary do
      <<before::binary-size(dibs_size_before), 0x01, 0xFD, 0x17, _error_code>> ->
        before
      _ ->
        dibs_binary
    end

    dibs =
      dibs_binary
      |> LibWmbus.Dib.parse_dib()
      |> filter_unknown_data()
      |> merge_data_into_parent()
      |> map_values()
      |> Enum.reduce(Map.new(), fn m, acc -> Map.merge(m, acc) end)
      |> Map.drop([:unit, :tariff, :memory_address, :sub_device])

    Enum.into(dibs, %{
      payload_style: type,
    })
    |> extend_reading()
  end
  def parse(payload, meta) do
    Logger.warn("Could not parse payload #{inspect payload} with frame_port #{inspect get_in(meta, [:meta, :frame_port])}")
    []
  end


  #--- Internals ---

  # This function will take whatever parse() returns and provides the possibility
  # to add some more fields to readings using do_extend_reading()
  defp extend_reading(readings) when is_list(readings), do: Enum.map(readings, &extend_reading(&1))
  defp extend_reading({fields, opts}), do: {extend_reading(fields), opts}
  defp extend_reading(%{} = fields), do: do_extend_reading(fields)
  defp extend_reading(other), do: other

  # Will remove all unknown fields from LibWmbus.Dib.parse_dib(payload) result.
  defp filter_unknown_data(parse_dib_result) do
    Enum.filter(parse_dib_result, fn
      (%{data: %{desc: desc}}) ->
        case to_string(desc) do
          <<"unkown_", _::binary>> -> false
          <<"unknown_", _::binary>> -> false
          _ -> true
        end
      (_) ->
        true
    end)
  end

  defp merge_data_into_parent(map) do
    Enum.map(map, fn
      %{data: data} = parent ->
        parent
        |> Map.merge(data)
        |> Map.delete(:data)
    end)
  end

  defp map_values(map) do
    map
    |> Enum.map(fn
      %{desc: :error_codes, value: v} = map ->
        Map.merge(map, %{
          :error_codes => v |> String.to_integer() |> Kernel.min(1),
          :error => v |> Base.decode16!() |> build_error_string(),
        })
      %{desc: :fabrication_block, value: v} = map ->
        Map.merge(map, %{:fabrication_block => v, :fabrication_block_unit => "MeterID"})
      %{desc: d = :energy, value: v, unit: "Wh"} = map ->
        Map.merge(map, %{d => Float.round(v / 1000, 3), :energy_unit => "kWh"})
      %{desc: d, value: v, unit: u} = map ->
        Map.merge(map, %{d => v, "#{d}_unit" => u})
    end)
    |> Enum.map(&(Map.drop(&1, [:desc, :value])))
  end

  defp build_error_string(<<status::binary-1>>), do: build_error_string(<<0>> <> status)
  defp build_error_string(<<bit15::1, bit14::1, bit13::1, bit12::1, eeprom_heads_up::1, dirt_heads_up::1, electronic_error::1, eight_hours_exceeded::1,
    internal_memory_disturbance::1, short_circuit_temperature_sensor_cold_side::1, short_circuit_temperature_sensor_warm_side::1,
    supply_voltage_low::1, electronic_malfunction::1, disruption_temperature_sensor_cold_side::1, disruption_temperature_sensor_warm_side::1,
    error_flow_measurement::1>>) do
    []
    |> concat_if(eeprom_heads_up, "EEPROM-Vorwarnung")
    |> concat_if(dirt_heads_up, "Verschmutzungs-Vorwarnung der Messstrecke")
    |> concat_if(electronic_error, "F9 - Fehler in der Elektronik (ASIC)")
    |> concat_if(eight_hours_exceeded, "F8 - F1, F2, F3, F5 oder F6 stehen länger als 8 Stunden an")
    |> concat_if(internal_memory_disturbance, "F7 - Störung im internen Speicher (ROM oder EEPROM)")
    |> concat_if(short_circuit_temperature_sensor_cold_side, "F6 - Kurzschluss Termperaturfühler kalte Seite")
    |> concat_if(short_circuit_temperature_sensor_warm_side, "F5 - Kurzschluss Termperaturfühler warme Seite")
    |> concat_if(supply_voltage_low, "F4 - Versorgungsspannung niedrig")
    |> concat_if(electronic_malfunction, "F3 - Elektronik für Temperaturauswertung defekt")
    |> concat_if(disruption_temperature_sensor_cold_side, "F2 - Unterbrechung Temperaturfühler kalte Seite")
    |> concat_if(disruption_temperature_sensor_warm_side, "F1 - Unterbrechung Temperaturfühler warme Seite")
    |> concat_if(error_flow_measurement, "F0 - Fehler bei Durchflussmessung (z.B. Luft im Messrohr)")
    |> concat_if(bit12, "Error bit 12 set")
    |> concat_if(bit13, "Error bit 13 set")
    |> concat_if(bit14, "Error bit 14 set")
    |> concat_if(bit15, "Error bit 15 set")
    |> Enum.reverse
    |> Enum.join(";")
  end

  defp concat_if(acc, 0, _), do: acc
  defp concat_if(acc, 1, string), do: [string | acc]

  def fields() do
    [
      %{
        field: "payload_style",
        display: "Payload Style",
      },
      %{
        field: "energy",
        display: "Energie",
        unit: "kWh",
      },
      %{
        field: "flow",
        display: "Fluss",
        unit: "m³/h",
      },
      %{
        field: "power",
        display: "Power",
        unit: "W",
      },
      %{
        field: "supply_temperature",
        display: "Vorlauftemperatur",
        unit: "°C",
      },
      %{
        field: "return_temperature",
        display: "Rücklauftemperatur",
        unit: "°C",
      },
      %{
        field: "volume",
        display: "Volumen",
        unit: "m³",
      },
    ]
  end

  # Function for testing. Run with `elixir -r payload_parser/elvaco_cmi4110/parser.exs -e "Parser.test()"`
  def tests() do
    [
      # From PDF
      {
        :parse_hex, "000C06384612000C14059753000B2D5201000B3B5706000A5A05030A5E05010C7889478268046D3231542302FD170000", %{}, %{
          "datetime_unit" => "",
          "flow_unit" => "m³/h",
          "power_unit" => "W",
          "return_temperature_unit" => "°C",
          "supply_temperature_unit" => "°C",
          "volume_unit" => "m³",
          :"6-0:1.0.0" => 124638.0,
          energy: 124638.0,
          energy_unit: "kWh",
          datetime: ~N[2018-03-20 17:50:00],
          error_codes: 0,
          error: "",
          fabrication_block: 68824789,
          fabrication_block_unit: "MeterID",
          flow: 0.657,
          function_field: :current_value,
          supply_temperature: 30.5,
          payload_style: 0,
          power: 15200,
          return_temperature: 10.5,
          volume: 5397.05,
        }
      },

      # From real device
      {
        :parse_hex, "000C06150110000C782791206802FD170600", %{}, %{
          "6-0:1.0.0": 100115.0,
          energy: 100115.0,
          energy_unit: "kWh",
          error_codes: 1,
          error: "F2 - Unterbrechung Temperaturfühler kalte Seite;F1 - Unterbrechung Temperaturfühler warme Seite",
          fabrication_block: 68209127,
          fabrication_block_unit: "MeterID",
          function_field: :current_value,
          payload_style: 0,
        }
      },

      # From real device
      {
        :parse_hex, "000C06748823000C14099850000B2D0801000B3B6201000A5A54090A5E79030C788851276702FD170000", %{}, %{
          "flow_unit" => "m³/h",
          "power_unit" => "W",
          "return_temperature_unit" => "°C",
          "supply_temperature_unit" => "°C",
          "volume_unit" => "m³",
          :"6-0:1.0.0" => 238874.0,
          energy: 238874.0,
          energy_unit: "kWh",
          error_codes: 0,
          error: "",
          flow: 0.162,
          function_field: :current_value,
          supply_temperature: 95.4,
          fabrication_block: 67275188,
          fabrication_block_unit: "MeterID",
          payload_style: 0,
          power: 10800,
          return_temperature: 37.9,
          volume: 5098.09
        }
      },
      {
        :parse_hex, "000C06365518000C14136528003B2E0000003B3E0000003A5B00003A5F00000C788414916502FD170304", %{}, %{
          "flow_unit" => "m³/h",
          "power_unit" => "W",
          "return_temperature_unit" => "°C",
          "supply_temperature_unit" => "°C",
          "volume_unit" => "m³",
          :energy => 185536.0,
          :"6-0:1.0.0" => 185536.0,
          :energy_unit => "kWh",
          :error => "Verschmutzungs-Vorwarnung der Messstrecke;F1 - Unterbrechung Temperaturfühler warme Seite;F0 - Fehler bei Durchflussmessung (z.B. Luft im Messrohr)",
          :error_codes => 1,
          :fabrication_block => 65911484,
          :fabrication_block_unit => "MeterID",
          :flow => 0,
          :function_field => :current_value,
          :payload_style => 0,
          :power => 0,
          :return_temperature => 0,
          :supply_temperature => 0,
          :volume => 2865.13,
        }
      },
      # From real device with error
      {
        :parse_hex, "010C07905510000C786734966902FD170040", %{}, %{
          energy: 1.0559e6,
         "6-0:1.0.0": 1.0559e6,
          energy_unit: "kWh",
          error: "Error bit 14 set",
          error_codes: 1,
          fabrication_block: 69963467,
          fabrication_block_unit: "MeterID",
          function_field: :current_value,
          payload_style: 1
        }
      },
      # From real device with error
      {
        :parse_hex, "1E04068E6002000413D6082200022B0000023B0000025A4300025E3B00077961576851A511400401FD1784", %{}, %{
        :"6-0:1.0.0" => 155790.0,
        :energy => 155790.0,
        :energy_unit => "kWh",
        :flow => 0.0,
        :function_field => :current_value,
        :payload_style => 30,
        :power => 0,
        :return_temperature => 5.9,
        :supply_temperature => 6.7,
        :volume => 2230.486,
        "flow_unit" => "m³/h",
        "power_unit" => "W",
        "return_temperature_unit" => "°C",
        "supply_temperature_unit" => "°C",
        "volume_unit" => "m³"
      }
      },
    ]
  end

end
