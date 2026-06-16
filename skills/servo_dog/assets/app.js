const API = '/api/lua/servo_dog';

const actionFallback = [
  { id: '1', label: '趴下' },
  { id: '2', label: '鞠躬' },
  { id: '3', label: '后仰' },
  { id: '4', label: '前后' },
  { id: '5', label: '摇摆' },
  { id: '6', label: '左右' },
  { id: '7', label: '握手' },
  { id: '8', label: '戳戳' },
  { id: '9', label: '抖腿' },
  { id: '10', label: '前跳' },
  { id: '11', label: '后跳' },
  { id: '12', label: '收腿' },
];

const state = {
  offsets: { fl: 0, fr: 0, bl: 0, br: 0 },
  selectedServo: null,
  actions: actionFallback,
  moves: [
    { id: 'F', label: '前进' },
    { id: 'B', label: '后退' },
    { id: 'L', label: '左转' },
    { id: 'R', label: '右转' },
  ],
  sequence: [],
};

function setStatus(text, isError = false) {
  const el = document.getElementById('status');
  el.textContent = text;
  el.classList.toggle('error', isError);
}

async function request(path, body) {
  const options = body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  };
  const response = await fetch(`${API}${path}`, options);
  const data = await response.json();
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || '请求失败');
  }
  return data;
}

function renderActions() {
  const actions = document.getElementById('actions');
  const select = document.getElementById('sequence-action');
  actions.innerHTML = '';
  select.innerHTML = '';

  state.actions.forEach((action) => {
    const button = document.createElement('button');
    button.textContent = action.label || action.name || action.id;
    button.onclick = () => sendControl({ action: action.id || action.name });
    actions.appendChild(button);

    const option = document.createElement('option');
    option.value = action.id || action.name;
    option.textContent = action.label || action.name || action.id;
    select.appendChild(option);
  });

  state.moves.forEach((move) => {
    const option = document.createElement('option');
    option.value = move.id;
    option.textContent = move.label;
    select.appendChild(option);
  });
}

function renderOffsets() {
  document.querySelectorAll('.servo').forEach((button) => {
    const servo = button.dataset.servo;
    button.querySelector('strong').textContent = state.offsets[servo] || 0;
    button.classList.toggle('active', servo === state.selectedServo);
  });

  const label = document.getElementById('selected-servo');
  label.textContent = state.selectedServo ? `${state.selectedServo}: ${state.offsets[state.selectedServo] || 0}` : '未选择';
}

function renderSequence() {
  const list = document.getElementById('sequence-list');
  list.innerHTML = '';
  state.sequence.forEach((item, index) => {
    const action = state.actions.find((candidate) => (candidate.id || candidate.name) === item.action)
      || state.moves.find((candidate) => candidate.id === item.action);
    const row = document.createElement('div');
    row.className = 'sequence-item';
    row.innerHTML = `
      <span>${action ? action.label : item.action}</span>
      <span>${item.delay}s</span>
      <button class="remove" data-index="${index}" aria-label="remove">x</button>
    `;
    list.appendChild(row);
  });
}

async function refreshState() {
  try {
    const data = await request('/state');
    state.offsets = data.offsets || state.offsets;
    state.actions = data.actions || actionFallback;
    state.moves = data.moves || state.moves;
    renderActions();
    renderOffsets();
    setStatus(data.calibration ? 'Calibration mode' : 'Ready');
  } catch (error) {
    setStatus(error.message, true);
  }
}

async function sendControl(body) {
  try {
    await request('/control', body);
    setStatus('Command sent');
  } catch (error) {
    setStatus(error.message, true);
  }
}

function loadSequence() {
  try {
    const saved = localStorage.getItem('servoDogSequence');
    state.sequence = saved ? JSON.parse(saved) : [];
  } catch {
    state.sequence = [];
  }
  renderSequence();
}

function bindControls() {
  document.querySelectorAll('[data-move]').forEach((button) => {
    button.onclick = () => sendControl({ move: button.dataset.move });
  });

  document.querySelectorAll('[data-action]').forEach((button) => {
    button.onclick = () => sendControl({ action: button.dataset.action });
  });

  document.getElementById('start-calibration').onclick = async () => {
    try {
      const data = await request('/start_calibration');
      state.offsets = data.offsets || state.offsets;
      renderOffsets();
      setStatus('Calibration mode');
    } catch (error) {
      setStatus(error.message, true);
    }
  };

  document.getElementById('exit-calibration').onclick = async () => {
    try {
      await request('/exit_calibration');
      setStatus('Ready');
    } catch (error) {
      setStatus(error.message, true);
    }
  };

  document.querySelectorAll('.servo').forEach((button) => {
    button.onclick = () => {
      state.selectedServo = button.dataset.servo;
      renderOffsets();
    };
  });

  async function adjust(delta) {
    if (!state.selectedServo) return;
    const current = state.offsets[state.selectedServo] || 0;
    const next = Math.max(-25, Math.min(25, current + delta));
    state.offsets[state.selectedServo] = next;
    renderOffsets();
    try {
      await request('/adjust', { servo: state.selectedServo, value: next });
      setStatus('Offset saved');
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  document.getElementById('minus').onclick = () => adjust(-1);
  document.getElementById('plus').onclick = () => adjust(1);

  document.getElementById('add-sequence').onclick = () => {
    if (state.sequence.length >= 8) {
      setStatus('最多添加 8 个动作', true);
      return;
    }
    const action = document.getElementById('sequence-action').value;
    const delay = Number(document.getElementById('sequence-delay').value);
    if (!action || Number.isNaN(delay) || delay < 0 || delay > 10) {
      setStatus('延迟需在 0 到 10 秒之间', true);
      return;
    }
    state.sequence.push({ action, delay });
    renderSequence();
  };

  document.getElementById('sequence-list').onclick = (event) => {
    if (!event.target.classList.contains('remove')) return;
    state.sequence.splice(Number(event.target.dataset.index), 1);
    renderSequence();
  };

  document.getElementById('save-sequence').onclick = () => {
    localStorage.setItem('servoDogSequence', JSON.stringify(state.sequence));
    setStatus('Sequence saved');
  };

  document.getElementById('play-sequence').onclick = async () => {
    for (const item of state.sequence) {
      const body = ['F', 'B', 'L', 'R'].includes(item.action)
        ? { move: item.action }
        : { action: item.action };
      await sendControl(body);
      await new Promise((resolve) => setTimeout(resolve, item.delay * 1000));
    }
  };
}

document.addEventListener('DOMContentLoaded', () => {
  bindControls();
  loadSequence();
  refreshState();
});
