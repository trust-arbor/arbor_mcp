defmodule Arbor.MCP.Internal.NetworkPolicy do
  @moduledoc false

  import Bitwise

  @spec public_address?(:inet.ip_address()) :: boolean()
  def public_address?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not restricted_ipv4?(a, b, c, d)
  end

  def public_address?({a, b, c, d, e, f, g, h} = address)
      when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
             e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    case address do
      {0, 0, 0, 0, 0, 65_535, high, low} ->
        public_address?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

      _other ->
        global_ipv6?(address) and not reserved_ipv6?(address)
    end
  end

  def public_address?(_address), do: false

  defp restricted_ipv4?(a, _b, _c, _d) when a in [0, 10, 127] or a >= 224, do: true
  defp restricted_ipv4?(100, b, _c, _d) when b in 64..127, do: true
  defp restricted_ipv4?(169, 254, _c, _d), do: true
  defp restricted_ipv4?(172, b, _c, _d) when b in 16..31, do: true
  defp restricted_ipv4?(192, b, _c, _d) when b in [0, 168], do: true
  defp restricted_ipv4?(192, 88, 99, _d), do: true
  defp restricted_ipv4?(198, b, _c, _d) when b in 18..19, do: true
  defp restricted_ipv4?(198, 51, 100, _d), do: true
  defp restricted_ipv4?(203, 0, 113, _d), do: true
  defp restricted_ipv4?(_a, _b, _c, _d), do: false

  defp global_ipv6?({first, _b, _c, _d, _e, _f, _g, _h}), do: (first &&& 0xE000) == 0x2000

  defp reserved_ipv6?({0x2001, 0x0DB8, _c, _d, _e, _f, _g, _h}), do: true
  defp reserved_ipv6?({0x3FFF, b, _c, _d, _e, _f, _g, _h}) when b <= 0x0FFF, do: true
  defp reserved_ipv6?({0x2001, 0x0000, _c, _d, _e, _f, _g, _h}), do: true
  defp reserved_ipv6?({0x2001, 0x0002, _c, _d, _e, _f, _g, _h}), do: true

  defp reserved_ipv6?({0x2001, b, _c, _d, _e, _f, _g, _h}) when b in 0x0010..0x002F,
    do: true

  defp reserved_ipv6?({0x2002, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp reserved_ipv6?(_address), do: false
end
