/* =========================================================
   颱風危機：設定檔（老師只需要改這個檔案）
   ========================================================= */
window.GAME_CONFIG = {

  /* ① 接上 Supabase 後，把下面兩格填好（兩格都填才會啟用連線版）
        supabaseUrl：Project URL，例如 'https://abcdefgh.supabase.co'
        supabaseKey：Publishable key（sb_publishable_ 開頭）或舊版 anon key
        ⚠️ 絕對不要貼 secret key 或 service_role key */
  supabaseUrl: 'https://ziygsfrsqtbjwunxkmow.supabase.co/rest/v1/',
  supabaseKey: 'sb_publishable_-u1GZ1nomwxo9f-th2S7iA_SOVTI4pw',

  /* ② 示範模式：上面兩格空白時使用。帳號和授權碼寫在這裡，紀錄只存在各自的裝置。
        正式上課請改用 Supabase，因為這個檔案任何人都看得到。 */
  demo: {
    codes: { 1: '1111', 2: '2222', 3: '3333' },
    accounts: [
      { account: 'demo', password: '1234', seat: 1, name: '示範工程師' },
      { account: 'demo2', password: '1234', seat: 2, name: '示範工程師二' }
    ]
  },

  /* ③ 示範模式的第三關時間（秒）。連線版改在 Supabase 的 levels 資料表設定。 */
  level3Seconds: 180,

  /* ④ true：第三關交卷後立刻顯示正解。課堂請維持 false，由老師公布。 */
  revealLevel3AnswersAfterSubmit: false
};
