//// A warm tick that fires late is dropped only when the cache is probably
//// gone. The grace is the margin the interval leaves less the ping's 5s
//// landing time, floored at the scheduler's jitter: the e2e fixture's 3s TTL
//// leaves 300ms, which a loaded machine overruns, while a real 5m TTL leaves
//// 25s. E2E cannot make a tick late on demand, so the arithmetic is pinned
//// here.

import albedo/harness/extensions/warm/extension
import gleeunit/should

pub fn a_real_ttl_keeps_its_margin_less_the_landing_test() -> Nil {
  // claude's 5m tier: pings every 270s, 30s of margin, 25s of grace
  extension.latest_ms(270_000, 300_000, 270_000)
  |> should.equal(295_000)
}

pub fn the_hour_tier_keeps_its_margin_less_the_landing_test() -> Nil {
  // pings every 3240s, 360s of margin, 355s of grace
  extension.latest_ms(3_240_000, 3_600_000, 3_240_000)
  |> should.equal(3_595_000)
}

pub fn a_tick_still_inside_the_cache_lifetime_pings_test() -> Nil {
  // 20s late at the 5m tier: the cache lives 10s more, so the ping goes out
  { 270_000 + 20_000 <= extension.latest_ms(270_000, 300_000, 270_000) }
  |> should.be_true
}

pub fn a_short_ttl_keeps_the_jitter_floor_test() -> Nil {
  // the fixture's 3s TTL: 2.7s interval, 300ms margin, under the landing time
  extension.latest_ms(2700, 3000, 2700)
  |> should.equal(4700)
}

pub fn a_sleeping_machine_is_past_every_grace_test() -> Nil {
  // woken an hour after the 5m tier's tick was due
  { 270_000 + 3_600_000 > extension.latest_ms(270_000, 300_000, 270_000) }
  |> should.be_true
}
