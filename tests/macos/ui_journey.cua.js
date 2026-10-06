// Run in cua_repl after selecting ONLY the app made by prepare_ui_fixture.py.
// Pass batches of 3–4 icons to stay below the tool call timeout.
// Real Codex is not targeted. The fixture action log is the independent
// dispatch oracle; this journey checks the actual editor and visible results.
var microUIEvidence = [];
async function checkMicroKeycap(micro, icon, glyphLabel, expectedAction, occurrence = 0) {
  let state;
  async function read() { state = await micro.getAXState({emit:false, disableDiffing:true}); }
  function index(pattern, at = 0) {
    const rows = state.split('\n').filter(row => pattern.test(row));
    if (!rows[at]) throw new Error('Missing visible UI element: ' + pattern);
    return Number(rows[at].trim().match(/^\d+/)[0]);
  }
  function escaped(value) { return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  await micro.pressKey('super+comma'); await read();
  await micro.click(index(/button Description: Edit key ACT06,/)); await read();
  await micro.setValue(index(/search text field.*Search keycaps/), icon); await read();
  await micro.click(index(new RegExp('button(?: \\(selected\\))? Description: ' + escaped(glyphLabel) + ','), occurrence)); await read();
  if (!state.includes('text Description: ' + icon + ',')) throw new Error('Incorrect keycap: ' + icon);
  const action = state.split('\n').find(row => row.includes('button Description: Action,'));
  if (!action?.includes('Value: ' + expectedAction + ',')) throw new Error('Incorrect default action: ' + action);
  await micro.click(index(/button Description: Save,/)); await read();
  await micro.click(index(/button Description: Close settings,/)); await read();
  const cap = state.split('\n').find(row => row.includes('button Description:') && row.includes('Value: ' + icon + ','));
  if (!cap) throw new Error('Saved keycap is absent: ' + icon);
  await micro.click(Number(cap.trim().match(/^\d+/)[0])); await read();
  if (['APPR','REJ'].includes(icon) && state.includes('popover')) throw new Error('No requests: must not open an empty approval popover');
  microUIEvidence.push({icon, action:expectedAction, result:'Pass', scope:'Micro UI to isolated native bridge'});
}
// After a batch, emit microUIEvidence with nodeRepl.write(). Compare actions.jsonl
// from the fixture directory against expected operation IDs. An unsupported
// default must produce no operation, even when the key is clicked.
