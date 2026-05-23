import { useEffect, useState } from 'react';

const API = '/api/todos';

export default function App() {
  const [todos, setTodos] = useState([]);
  const [text, setText]   = useState('');
  const [err, setErr]     = useState(null);
  const [busy, setBusy]   = useState(false);

  const load = async () => {
    setErr(null);
    try {
      const r = await fetch(API);
      if (!r.ok) throw new Error(`GET failed: ${r.status}`);
      setTodos(await r.json());
    } catch (e) { setErr(e.message); }
  };

  useEffect(() => { load(); }, []);

  const add = async (e) => {
    e.preventDefault();
    const t = text.trim();
    if (!t) return;
    setBusy(true);
    try {
      const r = await fetch(API, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: t }),
      });
      if (!r.ok) throw new Error(`POST failed: ${r.status}`);
      setText('');
      await load();
    } catch (e) { setErr(e.message); }
    finally    { setBusy(false); }
  };

  const toggle = async (todo) => {
    await fetch(`${API}/${todo.id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ done: !todo.done }),
    });
    load();
  };

  const remove = async (id) => {
    await fetch(`${API}/${id}`, { method: 'DELETE' });
    load();
  };

  return (
    <main>
      <h1>Todos</h1>
      <p className="sub">backend → Cosmos DB (workload identity, no static keys)</p>

      <form onSubmit={add}>
        <input
          autoFocus
          placeholder="What needs doing?"
          value={text}
          onChange={(e) => setText(e.target.value)}
          maxLength={280}
        />
        <button disabled={busy || !text.trim()}>Add</button>
      </form>

      {err && <p className="err">⚠ {err}</p>}

      <ul>
        {todos.map((t) => (
          <li key={t.id} className={t.done ? 'done' : ''}>
            <label>
              <input type="checkbox" checked={t.done} onChange={() => toggle(t)} />
              <span>{t.text}</span>
            </label>
            <button className="del" onClick={() => remove(t.id)} aria-label="delete">✕</button>
          </li>
        ))}
        {todos.length === 0 && !err && <li className="empty">no todos yet</li>}
      </ul>
    </main>
  );
}
