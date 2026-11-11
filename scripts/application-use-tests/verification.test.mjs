import test from 'node:test';
import assert from 'node:assert/strict';
import {classifyMonitor, findLabel, findFixtureLabel} from './verification.mjs';

const baseline = () => [
  {event:'ready', focusedWindowAvailable:true, windowNotifications:{focused:0}},
  {event:'heartbeat', samples:500, maxPollGapMs:21, windowReadFailures:0},
];
test('temporary disturbance remains inconclusive even after return to the original state', () => {
  for (const event of [
    {event:'pointer-change', from:[1,2], to:[5,6]},
    {event:'window-notification', kind:'AXFocusedWindowChanged'},
    {event:'application-activation', pid:222, isSentinel:false},
  ]) {
    assert.equal(classifyMonitor([...baseline(), event, {event:'application-activation', isSentinel:true}]).status,
      'inconclusive-desktop-activity');
  }
});
test('missing focus coverage or stalled monitor cannot pass', () => {
  assert.equal(classifyMonitor([]).status, 'incomplete');
  const noWindow = baseline(); noWindow[0].focusedWindowAvailable = false;
  assert.equal(classifyMonitor(noWindow).status, 'incomplete');
  const stalled = baseline(); stalled[1].maxPollGapMs = 200;
  assert.equal(classifyMonitor(stalled).status, 'incomplete');
  assert.equal(classifyMonitor(baseline()).status, 'passed-observed-interval');
});
test('letter lookup does not reuse numeric OCU element indexes', () => {
  assert.equal(findLabel('[AB] text field Background text', 'Background text'), 'AB');
  assert.equal(findLabel('  C button Background increment', 'Background increment'), 'C');
  assert.throws(() => findLabel('12 button Background increment', 'Background increment'));
});
test('demo accepts visible Chinese or AX labels and reports only fixture AX diagnostics', () => {
  const actual = '[A] OCR 右侧目标\n[B] AX AXButton 右侧目标\n[C] AX AXButton Demo lower target';
  assert.equal(findFixtureLabel(actual, '右侧目标', 'Demo right target'), 'B');
  assert.equal(findFixtureLabel(actual, '下方目标', 'Demo lower target'), 'C');
  assert.throws(() => findFixtureLabel(actual, 'missing'), error =>
    error.message.includes('[B] AX AXButton 右侧目标') && !error.message.includes('[A] OCR'));
});
