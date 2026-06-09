# CIDR Blocks

## What is an IP address?

Every device on a network — your laptop, a server, your phone — needs an address so other devices know how to find it. That address is called an **IP address**.

It looks like this: `192.168.1.5`

Four numbers, separated by dots. Each number is between 0 and 255.

Think of it exactly like a home address. Just like "123 Main St, Apt 4" tells the postal service where to deliver a package, an IP address tells the internet where to deliver data.

## Ranges of IP addresses

Now here's the thing — in your infrastructure you don't just work with one IP address at a time. You work with **groups** of them.

For example, your VPC (your private cloud network) owns a whole block of addresses. Your subnet owns a smaller block inside that. Your security rules say "allow traffic from this whole group of addresses."

So we need a way to say "I mean this address and all its neighbors" — not just one specific address.

That's what a CIDR block is. It's a way of writing down a **range** of IP addresses in one short expression.
