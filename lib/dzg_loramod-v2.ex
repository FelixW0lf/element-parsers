defmodule Parser do
  use Platform.Parsing.Behaviour
  require Logger

  # Parser for the DZG Plugin and Bridge using the v2.0 LoRaWAN Frame Format from file "LoRaWAN Frame Format 2.0.pdf".
  #
  # Changelog
  #   2018-11-28 [jb]: Reimplementation according to PDF.
  #   2018-12-03 [jb]: Handling MeterReading messages with missing frame header.
  #   2018-12-19 [jb]: Handling MeterReading messages with header v2. Fixed little encoding for some fields.
  #   2019-02-18 [jb]: Added option add_power_from_last_reading? that will calculate the power between register values.
  #   2019-04-29 [gw]: Also handle medium electricity with qualifier A_Plus.

  # Configuration

  # Will use the register_value from previous reading and add the field `power`.
  # Default: false
  def add_power_from_last_reading?(), do: false


  # Structure of payload deciffered from PDF:
  #
  # Payload
  #   FrameHeader
  #     version::2 == 0
  #     isEncrypted::1 == 0
  #     hasMac::1 == 0
  #     isCompressed::1 == 0
  #     type::3
  #   counter::32 # if isEncrypted
  #   frame::binary
  #
  # HINT: Values are little-endian!

  # Parsing the payload header with expected flags:
  # version = 0
  # isEncrypted = 0
  # hasMac = 0
  # isCompressed = 0
  def parse(<<0::2, 0::1, 0::1, 0::1, type::3, frame::binary>>, meta) do
    case type do
      0 -> # MeterReadingMessageEncrypted
        parse_meter_reading_message(frame, meta)
      1 -> # StatusMessage
        parse_status_message(frame)
      _ -> # Ignored: FrameTypeRawSerial and FrameTypeIec1107
        Logger.info("Unhandled frame type: #{inspect type}")
        []
    end
  end

  # Handling MeterReading messages without Header.
  def parse(<<frame::binary>>, %{meta: %{frame_port: 8}} = meta) do
    parse_meter_reading_message(frame, meta)
  end

  # Error handler
  def parse(payload, meta) do
    Logger.info("Can not parse frame with payload: #{inspect Base.encode16(payload)} on frame port: #{inspect get(meta, [:meta, :frame_port])}")
    []
  end


  # Parsing the frame data for a meter reading.
  #
  #   MeterReadingData
  #     MeterReadingMessageHeader
  #       UNION
  #         MeterReadingMessageHeaderVersion1
  #           version::2 == 1
  #           medium::3
  #           qualifier::3
  #         MeterReadingMessageHeaderVersion2
  #           version::2 == 2
  #           hasTimestamp::1
  #           isCompressed::1
  #           medium_extended::4
  #           qualifier::8
  #     meterId::32
  #     SEQUENCE
  #       MeterReadingDataTuple
  #         timestamp::32 # when hasTimestamp=1
  #         SEQUENCE
  #           RegisterValue::32
  #
  # Matching hard on medium 2=electricity_kwh here, to avoid problems with header v2
  def parse_meter_reading_message(<<1::2, 2::3, qualifier::3, meter_id::32-little, register_value::32-little>>, meta) do
    medium = 2
    %{
      type: "meter_reading",
      header_version: 1,
      medium: medium_name(medium),
      qualifier: medium_qualifier_name(medium, qualifier),
      meter_id: meter_id,
      register_value: register_value / 100,
    }
    |> add_power_from_last_reading(meta, :register_value, :power)
  end

  # Supporting MeterReadingMessageHeaderVersion2 with 2 byte length
  # Problem: the 2 byte header is little endian, so the version flag is at a DIFFERENT position than in MeterReadingMessageHeaderVersion1.
  def parse_meter_reading_message(<<qualifier::8, 2::2, has_timestamp::1, is_compressed::1, medium::4, rest::binary>>, meta) do
    case {{medium, qualifier, has_timestamp, is_compressed}, rest} do
      {{2, 4, 1, 0}, <<meter_id::32-little, timestamp::32-little, register_value::32-little, register2_value::32-little>>} ->
        create_basic_meter_reading_data(medium, qualifier, meter_id)
        |> add_register_values(timestamp, register_value, register2_value)
        |> add_power_from_last_reading(meta, :register_value, :power)
        |> add_power_from_last_reading(meta, :register2_value, :power2)
      {{2, 1, 1, 0}, <<meter_id::32-little, rest::binary>>} ->
        create_basic_meter_reading_data(medium, qualifier, meter_id)
        |> add_multiple_register_values(rest, 1)
        |> add_power_from_last_reading(meta, :register_value, :power)
        |> add_power_from_last_reading(meta, :register2_value, :power2)
      {header, binary} ->
        Logger.info("Not creating meter reading because not matching header #{inspect header} and reading_data #{Base.encode16 binary}")
        []
    end

  end

  def parse_meter_reading_message(_, _) do
    Logger.info("Unknown MeterReadingData format")
    []
  end

  defp create_basic_meter_reading_data(medium, qualifier, meter_id) do
    %{
      type: "meter_reading",
      header_version: 2,
      medium: medium_name_extended(medium),
      qualifier: medium_qualifier_name_extended(medium, qualifier),
      meter_id: meter_id
    }
  end

  defp add_register_values(map, timestamp, register_value, register2_value) do
    map
    |> Map.put(:register_value, register_value / 100)
    |> Map.put(:register2_value, register2_value / 100)
    |> Map.put(:timestamp_unix, timestamp)
    |> Map.put(:timestamp, DateTime.from_unix!(timestamp))
  end

  defp add_multiple_register_values(map, <<timestamp::32-little, register_value::32-little, rest::binary>>, i) do
    map
    |> Map.put(:"register_value_#{i}", register_value / 100)
    |> Map.put(:"timestamp_unix_#{i}", timestamp) # From device, can be wrong if device clock is wrong
    |> Map.put(:"timestamp_#{i}", DateTime.from_unix!(timestamp)) # From device, can be wrong if device clock is wrong
    |> add_multiple_register_values(rest, i + 1)
  end
  defp add_multiple_register_values(map, <<>>, _), do: map

  # Parsing the frame data for a status.
  #
  #   StatusData
  #     StatusDataFirstByte
  #       resetReason::3
  #       nodeType::2
  #       sessionInfo::3
  #     firmwareId::32
  #     uptime::32 # milliseconds
  #     time::32 # seconds, linux timestamp
  #     lastdownlinkPacked::32 # milliseconds
  #     DownlinkPacketInfo
  #       rssi::16
  #       snr::8
  #       frameType::8  # This was WRONG in PDF
  #       isAck::8   # This was WRONG in PDF
  #     numberOfConnectedDevices::8
  #
  def parse_status_message(<<reset_reason::3, node_type::2, session_info::3, firmware_id::binary-4, uptime_ms::32-little, time_s::32-little, last_downlink_ms::32-little, rssi::16-little, snr::8, frame_type::8, is_ack::8, connected_devices::8>>) do
    %{
      type: "status",
      reset_reason: reset_reason_name(reset_reason),
      node_type: node_type_name(node_type),
      session_info: session_info_name(session_info),
      firmware_id: Base.encode16(firmware_id),
      uptime_ms: uptime_ms,
      last_downlink_ms: last_downlink_ms,
      time_s: time_s,
      rssi: rssi,
      snr: snr,
      frame_type: frame_type,
      is_ack: is_ack,
      connected_devices: connected_devices,
    }
  end
  def parse_status_message(_) do
    Logger.warn("Unknown StatusData format")
    []
  end

  def add_power_from_last_reading(data, meta, register_field, power_field) do
    field_value = Map.get(data, register_field)
    case {add_power_from_last_reading?(), is_nil(field_value)} do
      {true, false} ->
        case get_last_reading(meta, [{register_field, :_}]) do
          %{measured_at: measured_at, data: last_data} ->

            field_last = get(last_data, [register_field])

            now_unix = DateTime.utc_now |> DateTime.to_unix
            reading_unix = measured_at |> DateTime.to_unix

            time_since_last_reading = now_unix - reading_unix

            power = (field_value - field_last) / (time_since_last_reading / 3600)

            Map.put(data, power_field, power)
          _ -> data # No previous reading
        end
      _ -> data # Not activated or missing field
    end
  end


  defp medium_qualifier_name(_, 0), do: "none"

  defp medium_qualifier_name(1, 1), do: "degreeCelsius"

  defp medium_qualifier_name(2, 1), do: "a-plus"
  defp medium_qualifier_name(2, 2), do: "a-plus-t1-t2"
  defp medium_qualifier_name(2, 4), do: "a-plus-a-minus"
  defp medium_qualifier_name(2, 5), do: "a-minus"
  defp medium_qualifier_name(2, 6), do: "a-plus-t1-t2-a-minus"

  defp medium_qualifier_name(3, 1), do: "volume"

  defp medium_qualifier_name(4, 1), do: "energy"

  defp medium_qualifier_name(6, 1), do: "tbd"

  defp medium_qualifier_name(7, 1), do: "volume"

  defp medium_qualifier_name(8, 1), do: "tbd"

  defp medium_qualifier_name(_, _), do: "unknown"

  defp medium_name(1), do: "temperature_celsius"
  defp medium_name(2), do: "electricity_kwh"
  defp medium_name(3), do: "gas_m3"
  defp medium_name(4), do: "heat_kwh"
  defp medium_name(6), do: "hotwater_m3"
  defp medium_name(7), do: "water_m3"
  defp medium_name(8), do: "heatcostallocator"
  defp medium_name(_), do: "unknown"

  defp session_info_name(0), do: "abp"
  defp session_info_name(1), do: "joined"
  defp session_info_name(2), do: "joinedLinkCheckFailed"
  defp session_info_name(3), do: "joinedLinkPeriodicRejoin"
  defp session_info_name(4), do: "joinedSessionResumed"
  defp session_info_name(5), do: "joinedSessionResumedJoinFailed"
  defp session_info_name(_), do: "unknown"

  defp node_type_name(0), do: "loramod"
  defp node_type_name(1), do: "brige"
  defp node_type_name(_), do: "unknown"

  defp reset_reason_name(0), do: "general"
  defp reset_reason_name(1), do: "backup"
  defp reset_reason_name(2), do: "wdt"
  defp reset_reason_name(3), do: "soft"
  defp reset_reason_name(4), do: "user"
  defp reset_reason_name(7), do: "slclk"
  defp reset_reason_name(_), do: "unknown"


  # Needed for MeterReadingMessageHeaderVersion2

  defp medium_name_extended(1), do: "temperature_celsius"
  defp medium_name_extended(2), do: "electricity_kwh"
  defp medium_name_extended(3), do: "gas_m3"
  defp medium_name_extended(4), do: "heat_kwh"
  defp medium_name_extended(6), do: "hotwater_m3"
  defp medium_name_extended(7), do: "water_m3"
  defp medium_name_extended(_), do: "unknown"

  defp medium_qualifier_name_extended(_, 0), do: "none"
  defp medium_qualifier_name_extended(2, 1), do: "a-plus"
  defp medium_qualifier_name_extended(2, 2), do: "a-plus-t1-t2"
  defp medium_qualifier_name_extended(2, 4), do: "a-plus-a-minus"
  defp medium_qualifier_name_extended(2, 5), do: "a-minus"
  defp medium_qualifier_name_extended(2, 6), do: "a-plus-t1-t2-a-minus"
  defp medium_qualifier_name_extended(2, 7), do: "a-plus-a-minus-r1-r2-r3-r4"
  defp medium_qualifier_name_extended(2, 8), do: "loadprofile"
  defp medium_qualifier_name_extended(_, _), do: "unknown"


  def fields do
    [
      %{
        "field" => "type",
        "display" => "Messagetype",
      },
      %{
        "field" => "medium",
        "display" => "Medium",
      },
      %{
        "field" => "meter_id",
        "display" => "Meter-ID",
      },
      %{
        "field" => "qualifier",
        "display" => "Qualifier",
      },
      %{
        "field" => "register_value",
        "display" => "Register-Value",
      },
    ]
  end

  def tests() do
    tests_with_last_reading() ++ [
      {
        # Meter Reading from Example in PDF
        :parse_hex, "0051294BBC000D000000", %{meta: %{frame_port: 8}}, %{
          header_version: 1,
          medium: "electricity_kwh",
          meter_id: 12340009,
          qualifier: "a-plus",
          register_value: 0.13,
          type: "meter_reading"
        },
      },

      {
        # Status Message from real device
        :parse_hex,  "0169008178E17F98F44A042D7B4F4B000000000000000001", %{meta: %{frame_port: 6}}, %{
          connected_devices: 1,
          firmware_id: "008178E1",
          frame_type: 0,
          is_ack: 0,
          last_downlink_ms: 75,
          node_type: "brige",
          reset_reason: "soft",
          rssi: 0,
          session_info: "joined",
          snr: 0,
          time_s: 1333472516,
          type: "status",
          uptime_ms: 1257543807,
        },
      },

      {
        # MeterReading Message from real device that somehow has no frame header.
        :parse_hex,  "513097F701B8030000", %{meta: %{frame_port: 8}}, %{
          header_version: 1,
          medium: "electricity_kwh",
          meter_id: 33003312,
          qualifier: "a-plus",
          register_value: 9.52,
          type: "meter_reading"
        },
      },

      # frameheader
      #    meterheader
      #         meterid
      #                  timestamp
      #                           register1
      #                                    register2
      # 00 04A2 0FE46503 27AA4F4B 83010000 00000000
      # 00 04A2 0FE46503 AEA64F4B 83010000 00000000
      {
        # MeterReading Message with header v2
        :parse_hex,  "0004A20FE4650327AA4F4B8301000000000000", %{meta: %{frame_port: 8}}, %{
          header_version: 2,
          medium: "electricity_kwh",
          meter_id: 57009167,
          qualifier: "a-plus-a-minus",
          register_value: 3.87,
          register2_value: 0.0,
          type: "meter_reading",
          timestamp: DateTime.from_unix!(1263512103),
          timestamp_unix: 1263512103,
        },
      },


      {
        # another MeterReading Message with header v2
        :parse_hex,  "0004A20FE46503AEA64F4B8301000000000000", %{meta: %{frame_port: 8}}, %{
          header_version: 2,
          medium: "electricity_kwh",
          meter_id: 57009167,
          qualifier: "a-plus-a-minus",
          register_value: 3.87,
          register2_value: 0.0,
          type: "meter_reading",
          timestamp: DateTime.from_unix!(1263511214),
          timestamp_unix: 1263511214,
        },
      },

      {
        # Electricity medium with A_Plus qualifier and 3 values
        :parse_hex, "0001A27D29370046237B4BCF0100002E227B4BCF01000062217B4BCF010000", %{meta: %{frame_port: 8}}, %{
          header_version: 2,
          medium: "electricity_kwh",
          meter_id: 3615101,
          qualifier: "a-plus",
          register_value_1: 4.63,
          register_value_2: 4.63,
          register_value_3: 4.63,
          type: "meter_reading",
          timestamp_1: DateTime.from_unix!(1266361158),
          timestamp_2: DateTime.from_unix!(1266360878),
          timestamp_3: DateTime.from_unix!(1266360674),
          timestamp_unix_1: 1266361158,
          timestamp_unix_2: 1266360878,
          timestamp_unix_3: 1266360674,
        }
      },

      {
        # Electricity medium with A_Plus qualifier and 4 values
        :parse_hex, "0001A277293700F7287A4B1A0400006B287A4B19040000B0277A4B1904000024277A4B19040000", %{meta: %{frame_port: 8}}, %{
          header_version: 2,
          medium: "electricity_kwh",
          meter_id: 3615095,
          qualifier: "a-plus",
          register_value_1: 10.5,
          register_value_2: 10.49,
          register_value_3: 10.49,
          register_value_4: 10.49,
          type: "meter_reading",
          timestamp_1: DateTime.from_unix!(1266297079),
          timestamp_2: DateTime.from_unix!(1266296939),
          timestamp_3: DateTime.from_unix!(1266296752),
          timestamp_4: DateTime.from_unix!(1266296612),
          timestamp_unix_1: 1266297079,
          timestamp_unix_2: 1266296939,
          timestamp_unix_3: 1266296752,
          timestamp_unix_4: 1266296612,
        }
      },

      {
        # Testing error handler
        :parse_hex,  "", %{meta: %{frame_port: 8}}, [],
      },
    ]
  end

  def tests_with_last_reading() do
    if (add_power_from_last_reading?()) do

      measured_at = Timex.now |> Timex.shift(hours: -1)

      last_reading_register_value = %{measured_at: measured_at, data: %{"register_value" => 0.09}}
      last_reading_register2_value = %{measured_at: measured_at, data: %{"register2_value" => 0.0}}

      [
        {
          # Meter Reading from Example in PDF
          :parse_hex, "0051294BBC000D000000", %{meta: %{frame_port: 8}, _last_reading__register_value__: last_reading_register_value}, %{
            header_version: 1,
            medium: "electricity_kwh",
            meter_id: 12340009,
            power: 0.04000000000000001,
            qualifier: "a-plus",
            register_value: 0.13,
            type: "meter_reading"
          },
        },

        {
          # MeterReading Message from real device that somehow has no frame header.
          :parse_hex,  "513097F701B8030000", %{meta: %{frame_port: 8}, _last_reading__register_value__: last_reading_register_value}, %{
            header_version: 1,
            medium: "electricity_kwh",
            meter_id: 33003312,
            power: 9.43,
            qualifier: "a-plus",
            register_value: 9.52,
            type: "meter_reading"
          },
        },

        {
          # MeterReading Message with header v2
          :parse_hex,  "0004A20FE4650327AA4F4B8301000000000000", %{meta: %{frame_port: 8}, _last_reading__register_value__: last_reading_register_value, _last_reading__register2_value__: last_reading_register2_value}, %{
            header_version: 2,
            medium: "electricity_kwh",
            meter_id: 57009167,
            qualifier: "a-plus-a-minus",
            register_value: 3.87,
            register2_value: 0.0,
            power: 3.7800000000000002,
            power2: 0.0,
            type: "meter_reading",
            timestamp: DateTime.from_unix!(1263512103),
            timestamp_unix: 1263512103,
          },
        },
      ]
    else
      []
    end
  end

end