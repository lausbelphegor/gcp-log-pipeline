output "kafka_public_ip" { value = google_compute_instance.kafka.network_interface[0].access_config[0].nat_ip }
output "kafka_private_ip" { value = google_compute_instance.kafka.network_interface[0].network_ip }
output "elk_public_ip" { value = google_compute_instance.elk.network_interface[0].access_config[0].nat_ip }
output "elk_private_ip" { value = google_compute_instance.elk.network_interface[0].network_ip }
