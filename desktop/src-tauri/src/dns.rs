//! Bounded local DNS forwarder for the native Roblox shim.
use reqwest::blocking::Client;
use std::{collections::HashMap, net::{SocketAddr,UdpSocket}, sync::{Arc,Mutex,atomic::{AtomicBool,Ordering},mpsc}, thread, time::{Duration,Instant}};

pub struct DnsService { pub address: String, stop:Arc<AtomicBool> }
impl Drop for DnsService {fn drop(&mut self){self.stop.store(true,Ordering::Relaxed);}}
type Cache=Arc<Mutex<HashMap<Vec<u8>,(Instant,Vec<u8>)>>>;

fn cached_reply(cache:&Cache,query:&[u8])->Option<Vec<u8>>{
    let guard=cache.lock().ok()?;let (at,reply)=guard.get(&query[2..])?;
    if at.elapsed()>Duration::from_secs(30){return None;}
    let mut reply=reply.clone();reply[..2].copy_from_slice(&query[..2]);Some(reply)
}
impl DnsService {
    pub fn start(provider:&str,custom:&str)->Result<Option<Self>,String>{
        if provider=="system"{return Ok(None);}
        let endpoint=match provider{"quad9"=>"https://dns.quad9.net/dns-query","cloudflare"=>"https://cloudflare-dns.com/dns-query","google"=>"https://dns.google/dns-query","custom"=>"",_=>return Err("Unknown DNS provider".into())}.to_string();
        if provider=="custom" && custom.trim().is_empty(){return Err("Enter a custom DNS server or choose a provider".into());}
        let socket=Arc::new(UdpSocket::bind("127.0.0.1:0").map_err(|e|format!("Could not start local DNS: {e}"))?);
        socket.set_read_timeout(Some(Duration::from_millis(200))).map_err(|e|e.to_string())?;
        let address=socket.local_addr().map_err(|e|e.to_string())?.to_string();
        let stop=Arc::new(AtomicBool::new(false));let cache:Cache=Arc::new(Mutex::new(HashMap::new()));
        let (sender,receiver)=mpsc::sync_channel::<(Vec<u8>,SocketAddr)>(32);
        let receiver=Arc::new(Mutex::new(receiver));
        let client=Client::builder().timeout(Duration::from_secs(2)).user_agent("Quinta/0.1").build().map_err(|e|e.to_string())?;
        for _ in 0..4{
            let (socket,stop,cache,receiver,client,endpoint,custom)=(socket.clone(),stop.clone(),cache.clone(),receiver.clone(),client.clone(),endpoint.clone(),custom.to_string());
            thread::spawn(move||{while !stop.load(Ordering::Relaxed){
                let job={receiver.lock().unwrap().recv_timeout(Duration::from_millis(200))};
                let Ok((query,peer))=job else{continue;};
                if let Some(reply)=cached_reply(&cache,&query){let _=socket.send_to(&reply,peer);continue;}
                let answer=if endpoint.is_empty(){custom_query(&custom,&query)}else{
                    client.post(&endpoint).header("Content-Type","application/dns-message").header("Accept","application/dns-message").body(query.clone()).send().and_then(|r|r.error_for_status()).and_then(|r|r.bytes()).ok().map(|b|b.to_vec())
                };
                if let Some(answer)=answer.filter(|r|r.len()>=12 && r.len()<=4096 && r[..2]==query[..2]){
                    if answer[3]&15==0{let mut c=cache.lock().unwrap();if c.len()>=512{c.clear();}c.insert(query[2..].to_vec(),(Instant::now(),answer.clone()));}
                    let _=socket.send_to(&answer,peer);
                }else{
                    let mut failure=query.clone();failure[2]|=0x80;failure[3]=(failure[3]&0xf0)|2;
                    let _=socket.send_to(&failure,peer);
                }
            }});
        }
        let read_stop=stop.clone();thread::spawn(move||{let mut bytes=[0u8;4096];while !read_stop.load(Ordering::Relaxed){
            if let Ok((size,peer))=socket.recv_from(&mut bytes){if size>=12 && peer.ip().is_loopback(){let _=sender.try_send((bytes[..size].to_vec(),peer));}}
        }});
        Ok(Some(Self{address,stop}))
    }
}
fn custom_query(server:&str,query:&[u8])->Option<Vec<u8>>{
    let target=if server.contains(':'){server.to_string()}else{format!("{server}:53")};
    let socket=UdpSocket::bind("0.0.0.0:0").ok()?;socket.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    socket.connect(target).ok()?;socket.send(query).ok()?;let mut reply=[0u8;4096];let len=socket.recv(&mut reply).ok()?;Some(reply[..len].to_vec())
}

#[cfg(test)]mod tests{use super::*;
    #[test]fn cache_rewrites_only_the_transaction_id(){let cache:Cache=Arc::new(Mutex::new(HashMap::new()));let q=vec![1,2,1,0,0,1,0,0,0,0,0,0];let mut reply=q.clone();reply[2]=0x81;cache.lock().unwrap().insert(q[2..].to_vec(),(Instant::now(),reply));let mut next=q.clone();next[..2].copy_from_slice(&[7,8]);let answer=cached_reply(&cache,&next).unwrap();assert_eq!(&answer[..2],&[7,8]);assert_eq!(answer[2],0x81);}
    #[test]fn expired_entries_are_not_returned(){let cache:Cache=Arc::new(Mutex::new(HashMap::new()));let q=vec![0;12];cache.lock().unwrap().insert(q[2..].to_vec(),(Instant::now()-Duration::from_secs(60),q.clone()));assert!(cached_reply(&cache,&q).is_none());}
}
#[cfg(test)]mod live{use super::*;
    // Network test: cargo test -- --ignored
    #[test]#[ignore]fn resolves_through_doh(){
        let svc=DnsService::start("quad9","").unwrap().unwrap();
        let s=UdpSocket::bind("127.0.0.1:0").unwrap();s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut q=vec![0x12,0x34,1,0,0,1,0,0,0,0,0,0];for l in "apis.roblox.com".split('.'){q.push(l.len() as u8);q.extend(l.bytes());}q.extend([0,0,1,0,1]);
        s.send_to(&q,&svc.address).unwrap();let mut b=[0u8;4096];let n=s.recv(&mut b).unwrap();
        assert!(n>=12);assert_eq!(b[3]&15,0,"DoH lookup failed (Quad9 needs HTTP/2)");assert!(u16::from_be_bytes([b[6],b[7]])>0);
    }
}
