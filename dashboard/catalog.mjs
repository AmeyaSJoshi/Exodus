import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs';
const key=process.env.ANON;
const c=createClient('http://127.0.0.1:54321',key);
const a=await c.auth.signInWithPassword({email:'viewer@egress.test',password:'egress-viewer-pw'});
console.log('login:', a.error?a.error.message:'OK');
const p=await c.rpc('my_profile'); console.log('my_profile:', JSON.stringify(p.data), p.error?.message??'');
const b=await c.rpc('organization_buildings'); console.log('catalog:', JSON.stringify(b.data)?.slice(0,300), b.error?.message??'');
process.exit(0);
