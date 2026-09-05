/* Supabase adapter for the legacy GAS UI. It preserves the old callback API
   while the data source moves from Google Apps Script to Supabase. */
(function () {
  const SUPABASE_URL = 'https://htptdhkhoxktvhgicutq.supabase.co';
  const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_1fMc83XXLsy7VaRFAp5FRg_kS9ci6UX';
  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  window.shopSupabase = client;

  const fail = (message) => ({ status: 'error', message });
  const toDate = (value) => value ? String(value).slice(0, 10) : '';
  const txToLegacy = (row) => ({
    transaction_id: row.id,
    'ประเภท': row.transaction_type,
    'วันที่': toDate(row.transaction_date),
    'ชื่อร้าน': row.store_name || '',
    'หมวดหมู่สินค้า': row.category || '',
    'รายการ': row.item_name || '',
    'จำนวนเงิน (บาท)': Number(row.amount || 0),
    'รวม (บาท)': Number(row.total || 0),
    'สถานะ': row.status || '',
    'วันที่จ่ายเงิน': toDate(row.payment_date),
    'หมายเหตุ': row.note || '',
    'ยอดคงเหลือ': row.balance == null ? '' : Number(row.balance),
    'คอลัมน์ 1': row.legacy_transaction_id || row.id
  });

  async function currentUser() {
    const { data, error } = await client.auth.getUser();
    if (error || !data.user) return (await client.auth.signInAnonymously()).data.user;
    return data.user;
  }

  async function appData() {
    const user = await currentUser();
    // PostgREST returns at most 1,000 rows by default. Fetch in pages so the
    // dashboard and table always use the complete migrated dataset.
    async function fetchAll(queryFactory, pageSize = 1000) {
      const rows = [];
      for (let from = 0; ; from += pageSize) {
        const result = await queryFactory().range(from, from + pageSize - 1);
        if (result.error) throw result.error;
        rows.push(...(result.data || []));
        if (!result.data || result.data.length < pageSize) return rows;
      }
    }
    const [tx, suppliers, products] = await Promise.all([
      fetchAll(() => client.from('transactions').select('*').order('transaction_date', { ascending: false })),
      fetchAll(() => client.from('suppliers').select('*').order('supplier_name')),
      fetchAll(() => client.from('products').select('*').order('product_name'))
    ]);
    const records = tx.map(txToLegacy);
    const supplierRows = suppliers.map(r => ({ __rowId: r.id, SupplierID: r.supplier_id || r.id, SupplierName: r.supplier_name }));
    const productRows = products.map(r => ({ __rowId: r.id, ProductID: r.product_id || r.id, ProductName: r.product_name, Category: r.category || '' }));
    const uniq = (values) => [...new Set(values.filter(Boolean))].sort();
    return {
      status: 'success', records, suppliers: supplierRows, products: productRows,
      dropdownData: {
        types: uniq(['รายรับ', 'รายจ่าย', ...records.map(r => r['ประเภท'])]),
        shopNames: uniq([...supplierRows.map(r => r.SupplierName), ...records.map(r => r['ชื่อร้าน'])]),
        categories: uniq(['อุปโภค', 'บริโภค', 'อื่นๆ', ...productRows.map(r => r.Category), ...records.map(r => r['หมวดหมู่สินค้า'])]),
        items: uniq([...productRows.map(r => r.ProductName), ...records.map(r => r['รายการ'])]),
        statuses: uniq(['ยังไม่จ่าย', 'จ่ายแล้ว', 'รอจ่าย', 'อื่นๆ', ...records.map(r => r['สถานะ'])])
      }
    };
  }

  async function call(name, args) {
    const user = await currentUser();
    if (name === 'getInitialData' || name === 'getUpdatedAppData') return appData();
    if (name === 'saveTransaction' || name === 'updateTransaction') {
      const payload = name === 'updateTransaction' ? JSON.parse(args[1]) : JSON.parse(args[0]);
      const row = {
        user_id: user.id, transaction_type: payload.type, transaction_date: payload.date,
        store_name: payload.shopName, category: payload.category, item_name: payload.item,
        amount: Number(payload.amount) || 0, total: Number(payload.amount) || 0,
        status: payload.status, payment_date: payload.paymentDate || null, note: payload.notes || null
      };
      const transactionId = name === 'updateTransaction' ? JSON.parse(args[0]).transaction_id : null;
      if (name === 'updateTransaction' && !transactionId) throw new Error('ไม่พบรหัสรายการสำหรับแก้ไข');
      const result = name === 'updateTransaction'
        ? await client.from('transactions').update(row).eq('id', transactionId).eq('user_id', user.id).select('id')
        : await client.from('transactions').insert(row).select('id');
      if (result.error) throw result.error;
      if (name === 'updateTransaction' && (!result.data || result.data.length !== 1)) throw new Error('ไม่พบรายการที่ต้องการแก้ไข หรือรายการถูกแก้ไขไปแล้ว');
      return appData();
    }
    if (name === 'deleteTransaction') {
      const payload = JSON.parse(args[0]);
      const transactionId = payload.transaction_id || payload.id;
      if (!transactionId) throw new Error('ไม่พบรหัสรายการสำหรับลบ');
      const result = await client.from('transactions').delete().eq('id', transactionId).eq('user_id', user.id).select('id');
      if (result.error) throw result.error;
      if (!result.data || result.data.length !== 1) throw new Error('ไม่พบรายการที่ต้องการลบ หรือรายการถูกลบไปแล้ว');
      return appData();
    }
    if (name === 'saveSupplier') {
      const p = JSON.parse(args[0]);
      if (!p.SupplierID || !p.SupplierName) throw new Error('ข้อมูลผู้ขายไม่ครบถ้วน');
      let result;
      if (p.row_id) {
        result = await client.from('suppliers').update({ supplier_id: p.SupplierID, supplier_name: p.SupplierName }).eq('id', p.row_id).eq('user_id', user.id).select('id');
      } else {
        const existing = await client.from('suppliers').select('id').eq('user_id', user.id).eq('supplier_id', p.SupplierID).limit(1);
        if (existing.error) throw existing.error;
        if (existing.data && existing.data.length) throw new Error(`รหัสผู้ขาย ${p.SupplierID} มีอยู่แล้ว ไม่บันทึกซ้ำ`);
        result = await client.from('suppliers').insert({ user_id: user.id, supplier_id: p.SupplierID, supplier_name: p.SupplierName }).select('id');
      }
      if (result.error) throw result.error;
      if (!result.data || result.data.length !== 1) throw new Error('ไม่พบผู้ขายที่ต้องการแก้ไข หรือข้อมูลถูกเปลี่ยนไปแล้ว');
      return appData();
    }
    if (name === 'deleteSupplier') {
      const p = typeof args[0] === 'string' ? { row_id: null, SupplierID: args[0] } : JSON.parse(args[0]);
      if (!p.row_id) throw new Error('การลบผู้ขายต้องอ้างอิงรายการที่เลือกโดยตรง เพื่อป้องกันลบหลายรายการ');
      const result = await client.from('suppliers').delete().eq('id', p.row_id).eq('user_id', user.id).select('id');
      if (result.error) throw result.error;
      if (!result.data || result.data.length !== 1) throw new Error('ไม่พบผู้ขายที่ต้องการลบ หรือผู้ขายถูกลบไปแล้ว');
      return appData();
    }
    if (name === 'saveProduct') {
      const p = JSON.parse(args[0]);
      if (!p.ProductID || !p.ProductName || !p.Category) throw new Error('ข้อมูลสินค้าไม่ครบถ้วน');
      let result;
      if (p.row_id) {
        result = await client.from('products').update({ product_id: p.ProductID, product_name: p.ProductName, category: p.Category }).eq('id', p.row_id).eq('user_id', user.id).select('id');
      } else {
        const existing = await client.from('products').select('id').eq('user_id', user.id).eq('product_id', p.ProductID).limit(1);
        if (existing.error) throw existing.error;
        if (existing.data && existing.data.length) throw new Error(`รหัสสินค้า ${p.ProductID} มีอยู่แล้ว ไม่บันทึกซ้ำ`);
        result = await client.from('products').insert({ user_id: user.id, product_id: p.ProductID, product_name: p.ProductName, category: p.Category }).select('id');
      }
      if (result.error) throw result.error;
      if (!result.data || result.data.length !== 1) throw new Error('ไม่พบสินค้าที่ต้องการแก้ไข หรือข้อมูลถูกเปลี่ยนไปแล้ว');
      return appData();
    }
    if (name === 'deleteProduct') {
      const p = typeof args[0] === 'string' ? { row_id: null, ProductID: args[0] } : JSON.parse(args[0]);
      if (!p.row_id) throw new Error('การลบสินค้าต้องอ้างอิงรายการที่เลือกโดยตรง เพื่อป้องกันลบหลายรายการ');
      const result = await client.from('products').delete().eq('id', p.row_id).eq('user_id', user.id).select('id');
      if (result.error) throw result.error;
      if (!result.data || result.data.length !== 1) throw new Error('ไม่พบสินค้าที่ต้องการลบ หรือสินค้าถูกลบไปแล้ว');
      return appData();
    }
    throw new Error(`ไม่รองรับฟังก์ชัน ${name}`);
  }

  function runner(success, failure) {
    return new Proxy({}, { get: (_, name) => (...args) => {
      call(name, args).then(result => success && success(JSON.stringify(result))).catch(error => failure && failure(error));
    }});
  }

  window.google = window.google || {};
  window.google.script = window.google.script || {};
  const bridgeRun = {
    _success: null,
    _failure: null,
    withSuccessHandler(fn) { this._success = fn; return bridgeProxy; },
    withFailureHandler(fn) { this._failure = fn; return bridgeProxy; }
  };
  const bridgeProxy = new Proxy(bridgeRun, {
    get(target, name) {
      if (name in target) return typeof target[name] === 'function' ? target[name].bind(target) : target[name];
      return (...args) => runner(target._success, target._failure)[name](...args);
    }
  });
  window.google.script.run = bridgeProxy;

  async function addLogin() {
    const { data: { session } } = await client.auth.getSession();
    if (session) return;
    if (document.getElementById('supabase-login-gate')) return;
    const gate = document.createElement('div');
    gate.id = 'supabase-login-gate';
    gate.style.cssText = 'position:fixed;inset:0;background:rgba(15,23,42,.72);z-index:99999;display:flex;align-items:center;justify-content:center;font-family:Sarabun,sans-serif';
    gate.innerHTML = '<div style="background:#fff;border-radius:16px;padding:28px;max-width:360px;width:calc(100% - 32px);text-align:center;box-shadow:0 20px 60px #0004"><h2>เข้าสู่ระบบร้านค้า</h2><p>เลือกบัญชีสำหรับเข้าใช้งาน</p><button id="login-google" class="btn btn-primary" style="width:100%;margin:6px 0">เข้าสู่ระบบด้วย Google</button><button id="login-github" class="btn" style="width:100%;margin:6px 0;background:#111827;color:#fff">เข้าสู่ระบบด้วย GitHub</button></div>';
    document.body.appendChild(gate);
    const redirectTo = window.location.origin + window.location.pathname;
    document.getElementById('login-google').onclick = () => client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo } });
    document.getElementById('login-github').onclick = () => client.auth.signInWithOAuth({ provider: 'github', options: { redirectTo } });
    client.auth.onAuthStateChange((_event, nextSession) => {
      if (nextSession) gate.remove();
    });
  }
  // Access is intentionally link-based for this internal deployment.
  // Do not block the application behind a provider login gate.
})();
