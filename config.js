/*
  Edit this file with your uncle's real details.
  Leave SUPABASE_URL and SUPABASE_ANON_KEY as they are to run in demo mode
  (requests are saved only in your own browser, good for testing).
  When you finish the steps in README.md, paste your real keys here.
*/
window.SITE_CONFIG = {
  BUSINESS_NAME: "Uncle's Welding Works",

  // WhatsApp number used when a customer picks "Any available welder".
  // Use the international format with no plus sign, for example 2348031234567
  FALLBACK_WHATSAPP: "2348106285867",

  PHONE_DISPLAY: "081 0628 5867",
  ADDRESS: "Workshop address here",
  HOURS: "Mon to Sat, 8am to 6pm",

  // Photos of finished work. Put image files in this folder and list them here.
  // Example: { src: "cage1.jpg", caption: "Two-level dog cage" }
  GALLERY: [],

  SUPABASE_URL: "https://acmahsvfruveqneyvbhs.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_E1TueTCtyOKygwYToKK3VQ_yCpFBnTu",

  // Public half of the phone-push keys. The private half lives ONLY in the
  // Supabase edge function's secrets - never put it in this file.
  PUSH_PUBLIC_KEY: "BGuf725j23QywnDe_XKxvIAfQkS0qVWGO8KcLstP8Hd0kcRwFv1D9OABJNyTFYn67dL8N4yRdftf-Mdjy2s4GKE",

  // Welder plan prices in naira per month. Keep these the same numbers as
  // the start_payment function in supabase-setup.sql.
  PRICES_NGN: { pro: 2000, featured: 4000 },

  // The workshop's bank account. Welders transfer the plan price here
  // (shown when they tap Go Pro / Go Featured), and the owner approves
  // it in the Money tab after checking the OPay app.
  BANK: {
    bank: "OPay",
    number: "8106285867",
    holder: "Monisola Omolabake Shodimu"
  },

  // AUTOMATIC payments: paste your OPay Merchant ID here (OPay dashboard
  // -> Settings -> API keys) AND set the matching Supabase edge-function
  // secrets - full steps in "OPAY-SETUP (paste into Supabase).txt".
  // Welders then pay on OPay's secure page and their plan switches on
  // by itself. Leave "" and they use the bank-transfer box above and
  // you approve each payment in the Money tab (works with zero setup).
  OPAY_MERCHANT_ID: ""
};
