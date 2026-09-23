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
  PUSH_PUBLIC_KEY: "BGuf725j23QywnDe_XKxvIAfQkS0qVWGO8KcLstP8Hd0kcRwFv1D9OABJNyTFYn67dL8N4yRdftf-Mdjy2s4GKE"
};
